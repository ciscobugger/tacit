/*
 * quiet-btagent: the pairing agent for this desktop's Bluetooth.
 *
 * BlueZ never asks the user anything itself. It calls org.bluez.Agent1 on whoever registered as
 * the agent, and with no agent registered every device that wants a confirmation, a passkey or a
 * PIN fails to pair -- from the shell's side the switch simply does nothing. Quickshell can talk
 * to D-Bus but cannot export an object on it, so the agent has to live in a program of its own.
 * This is that program, a sibling of quiet-filemanager1 and built the same way.
 *
 *   BlueZ -> Agent1 method  ->  one JSON line to the shell   ->  the sheet asks
 *   the sheet answers       ->  one plain line back          ->  the method returns
 *
 * The socket is $XDG_RUNTIME_DIR/bt-agent.sock, 0600, same shape as flowd's. Nothing is answered
 * on the user's behalf: with no shell connected the pairing is rejected, so the remote device says
 * so instead of waiting for a dialog that will never appear.
 *
 *   ./build.sh          (then ./install.sh)
 */
#include <gio/gio.h>
#include <gio/gunixsocketaddress.h>
#include <glib/gstdio.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>

/* BlueZ gives up on an agent that does not answer, and a sheet nobody is looking at should not
 * hold the pairing open for longer than the person who walked away from it. */
#define ASK_SECONDS 60

/* KeyboardDisplay: this machine has both, so BlueZ picks the best method the pair supports
 * (numeric comparison for anything modern) instead of falling back to a typed PIN. */
#define CAPABILITY "KeyboardDisplay"
#define AGENT_PATH "/org/tacit/btagent"

static GMainLoop *loop;
static GDBusConnection *bus;
static GList *clients;            /* GOutputStream* -- the shell, and its next instance while the old one closes */
static GHashTable *asks;          /* id -> Ask*, every question BlueZ is still waiting on */
static guint next_id = 1;

static const gchar introspection[] =
    "<node>"
    "  <interface name='org.bluez.Agent1'>"
    "    <method name='Release'/>"
    "    <method name='RequestPinCode'>"
    "      <arg type='o' name='device' direction='in'/>"
    "      <arg type='s' name='pincode' direction='out'/>"
    "    </method>"
    "    <method name='DisplayPinCode'>"
    "      <arg type='o' name='device' direction='in'/>"
    "      <arg type='s' name='pincode' direction='in'/>"
    "    </method>"
    "    <method name='RequestPasskey'>"
    "      <arg type='o' name='device' direction='in'/>"
    "      <arg type='u' name='passkey' direction='out'/>"
    "    </method>"
    "    <method name='DisplayPasskey'>"
    "      <arg type='o' name='device' direction='in'/>"
    "      <arg type='u' name='passkey' direction='in'/>"
    "      <arg type='q' name='entered' direction='in'/>"
    "    </method>"
    "    <method name='RequestConfirmation'>"
    "      <arg type='o' name='device' direction='in'/>"
    "      <arg type='u' name='passkey' direction='in'/>"
    "    </method>"
    "    <method name='RequestAuthorization'>"
    "      <arg type='o' name='device' direction='in'/>"
    "    </method>"
    "    <method name='AuthorizeService'>"
    "      <arg type='o' name='device' direction='in'/>"
    "      <arg type='s' name='uuid' direction='in'/>"
    "    </method>"
    "    <method name='Cancel'/>"
    "  </interface>"
    "</node>";

typedef struct {
    guint id;
    GDBusMethodInvocation *invocation;   /* NULL for a code we only show; returning consumes it */
    const gchar *kind;                   /* pin | passkey | confirm | authorize | service */
    guint timeout_id;
} Ask;

static void ask_free(gpointer p) {
    Ask *a = p;
    if (a->timeout_id) g_source_remove(a->timeout_id);
    g_free(a);
}

/* ── the shell ─────────────────────────────────────────────────────────────── */

static void json_escape(GString *out, const gchar *s) {
    for (; s && *s; s++) {
        switch (*s) {
        case '"':  g_string_append(out, "\\\""); break;
        case '\\': g_string_append(out, "\\\\"); break;
        case '\n': g_string_append(out, "\\n"); break;
        case '\r': g_string_append(out, "\\r"); break;
        case '\t': g_string_append(out, "\\t"); break;
        default:
            if ((guchar)*s < 0x20) g_string_append_printf(out, "\\u%04x", *s);
            else g_string_append_c(out, *s);
        }
    }
}

/* Every connected shell gets the line; one that has gone away is dropped here rather than
 * being discovered later with a pending question already waiting on it. */
static void to_shell(const gchar *line) {
    GList *dead = NULL;
    for (GList *l = clients; l; l = l->next) {
        GOutputStream *os = l->data;
        if (!g_output_stream_write_all(os, line, strlen(line), NULL, NULL, NULL)
            || !g_output_stream_flush(os, NULL, NULL))
            dead = g_list_prepend(dead, os);
    }
    for (GList *l = dead; l; l = l->next) {
        clients = g_list_remove(clients, l->data);
        g_object_unref(l->data);
    }
    g_list_free(dead);
}

/* The device's own name and address, read at the moment of the question: BlueZ hands the agent an
 * object path, and a sheet that says "pair with /org/bluez/hci0/dev_AA_BB" tells the user nothing. */
static void device_facts(const gchar *path, gchar **name, gchar **address) {
    *name = NULL;
    *address = NULL;
    GVariant *r = g_dbus_connection_call_sync(
        bus, "org.bluez", path, "org.freedesktop.DBus.Properties", "GetAll",
        g_variant_new("(s)", "org.bluez.Device1"), G_VARIANT_TYPE("(a{sv})"),
        G_DBUS_CALL_FLAGS_NONE, 2000, NULL, NULL);
    if (r) {
        GVariant *props = g_variant_get_child_value(r, 0);
        GVariant *v;
        if ((v = g_variant_lookup_value(props, "Alias", G_VARIANT_TYPE_STRING))
            || (v = g_variant_lookup_value(props, "Name", G_VARIANT_TYPE_STRING))) {
            *name = g_variant_dup_string(v, NULL);
            g_variant_unref(v);
        }
        if ((v = g_variant_lookup_value(props, "Address", G_VARIANT_TYPE_STRING))) {
            *address = g_variant_dup_string(v, NULL);
            g_variant_unref(v);
        }
        g_variant_unref(props);
        g_variant_unref(r);
    }
    if (!*address) *address = g_strdup("");
    if (!*name) *name = g_strdup(*address[0] ? *address : "This device");
}

static gboolean ask_too_slow(gpointer data) {
    Ask *a = data;
    a->timeout_id = 0;
    if (a->invocation)
        g_dbus_method_invocation_return_dbus_error(a->invocation, "org.bluez.Error.Canceled",
                                                   "Nobody answered the pairing request");
    GString *s = g_string_new("{\"ev\":\"hide\",\"id\":");
    g_string_append_printf(s, "%u}\n", a->id);
    to_shell(s->str);
    g_string_free(s, TRUE);
    g_hash_table_remove(asks, GUINT_TO_POINTER(a->id));
    return G_SOURCE_REMOVE;
}

/* Ask the shell, and hold the D-Bus call until it answers. With no shell there is nothing to hold
 * the call for, so it is rejected at once: BlueZ then tells the device, which is the truth. */
static void ask(GDBusMethodInvocation *invocation, const gchar *kind, const gchar *device_path,
                const gchar *code, const gchar *uuid) {
    if (!clients) {
        if (invocation)
            g_dbus_method_invocation_return_dbus_error(invocation, "org.bluez.Error.Rejected",
                                                       "The desktop is not running its pairing sheet");
        return;
    }
    Ask *a = g_new0(Ask, 1);
    a->id = next_id++;
    a->invocation = invocation;
    a->kind = kind;
    a->timeout_id = g_timeout_add_seconds(ASK_SECONDS, ask_too_slow, a);
    g_hash_table_insert(asks, GUINT_TO_POINTER(a->id), a);

    gchar *name, *address;
    device_facts(device_path, &name, &address);
    GString *s = g_string_new("{\"ev\":\"ask\",\"id\":");
    g_string_append_printf(s, "%u,\"kind\":\"%s\",\"device\":\"", a->id, kind);
    json_escape(s, name);
    g_string_append(s, "\",\"address\":\"");
    json_escape(s, address);
    g_string_append(s, "\",\"code\":\"");
    json_escape(s, code ? code : "");
    g_string_append(s, "\",\"uuid\":\"");
    json_escape(s, uuid ? uuid : "");
    g_string_append(s, "\"}\n");
    to_shell(s->str);
    g_string_free(s, TRUE);
    g_free(name);
    g_free(address);
}

/* ── the shell's answers ───────────────────────────────────────────────────── */

static void answer(guint id, gboolean ok, const gchar *value) {
    Ask *a = g_hash_table_lookup(asks, GUINT_TO_POINTER(id));
    if (!a) return;                            /* already timed out, or BlueZ cancelled it */
    GDBusMethodInvocation *inv = a->invocation;
    a->invocation = NULL;
    if (inv) {
        if (!ok)
            g_dbus_method_invocation_return_dbus_error(inv, "org.bluez.Error.Rejected",
                                                       "Refused on the desktop");
        else if (g_str_equal(a->kind, "pin"))
            g_dbus_method_invocation_return_value(inv, g_variant_new("(s)", value ? value : ""));
        else if (g_str_equal(a->kind, "passkey"))
            g_dbus_method_invocation_return_value(
                inv, g_variant_new("(u)", (guint32)g_ascii_strtoull(value ? value : "0", NULL, 10)));
        else
            g_dbus_method_invocation_return_value(inv, NULL);
    }
    g_hash_table_remove(asks, GUINT_TO_POINTER(id));
}

/* `ok <id>` | `no <id>` | `value <id> <text>`. Plain lines, not JSON: the shell is the only writer
 * and a parser in C is one more thing to get wrong. */
static void from_shell(const gchar *line) {
    gchar **f = g_strsplit(line, " ", 3);
    if (f[0] && f[1]) {
        guint id = (guint)g_ascii_strtoull(f[1], NULL, 10);
        if (g_str_equal(f[0], "ok")) answer(id, TRUE, NULL);
        else if (g_str_equal(f[0], "no")) answer(id, FALSE, NULL);
        else if (g_str_equal(f[0], "value") && f[2]) answer(id, TRUE, g_strstrip(f[2]));
    }
    g_strfreev(f);
}

static void read_line(GDataInputStream *in, GAsyncResult *res, gpointer user);

static void read_next(GDataInputStream *in) {
    g_data_input_stream_read_line_async(in, G_PRIORITY_DEFAULT, NULL,
                                       (GAsyncReadyCallback)read_line, NULL);
}

static void read_line(GDataInputStream *in, GAsyncResult *res, gpointer user) {
    gsize len = 0;
    gchar *line = g_data_input_stream_read_line_finish(in, res, &len, NULL);
    if (!line) {                                /* the shell closed, or reloaded */
        GOutputStream *os = g_object_get_data(G_OBJECT(in), "out");
        if (os) {
            clients = g_list_remove(clients, os);
            g_object_unref(os);
        }
        g_object_unref(in);
        return;
    }
    from_shell(line);
    g_free(line);
    read_next(in);
}

static gboolean on_connect(GSocketService *svc, GSocketConnection *conn, GObject *src, gpointer u) {
    GOutputStream *os = g_object_ref(g_io_stream_get_output_stream(G_IO_STREAM(conn)));
    clients = g_list_prepend(clients, os);
    GDataInputStream *in = g_data_input_stream_new(g_io_stream_get_input_stream(G_IO_STREAM(conn)));
    g_object_set_data_full(G_OBJECT(in), "conn", g_object_ref(conn), g_object_unref);
    g_object_set_data(G_OBJECT(in), "out", os);
    read_next(in);
    return TRUE;
}

/* ── org.bluez.Agent1 ──────────────────────────────────────────────────────── */

static void method(GDBusConnection *c, const gchar *sender, const gchar *path, const gchar *iface,
                   const gchar *name, GVariant *params, GDBusMethodInvocation *invocation,
                   gpointer user) {
    const gchar *dev = NULL;
    if (g_str_equal(name, "Release")) {
        g_dbus_method_invocation_return_value(invocation, NULL);
    } else if (g_str_equal(name, "RequestPinCode")) {
        g_variant_get(params, "(&o)", &dev);
        ask(invocation, "pin", dev, NULL, NULL);
    } else if (g_str_equal(name, "RequestPasskey")) {
        g_variant_get(params, "(&o)", &dev);
        ask(invocation, "passkey", dev, NULL, NULL);
    } else if (g_str_equal(name, "RequestConfirmation")) {
        guint32 passkey = 0;
        g_variant_get(params, "(&ou)", &dev, &passkey);
        /* BlueZ sends the passkey as a number and the pair of devices must show the same six
         * digits, so a value under 100000 is padded rather than shown short. */
        gchar *code = g_strdup_printf("%06u", passkey);
        ask(invocation, "confirm", dev, code, NULL);
        g_free(code);
    } else if (g_str_equal(name, "RequestAuthorization")) {
        g_variant_get(params, "(&o)", &dev);
        ask(invocation, "authorize", dev, NULL, NULL);
    } else if (g_str_equal(name, "AuthorizeService")) {
        const gchar *uuid = NULL;
        g_variant_get(params, "(&o&s)", &dev, &uuid);
        ask(invocation, "service", dev, NULL, uuid);
    } else if (g_str_equal(name, "DisplayPasskey") || g_str_equal(name, "DisplayPinCode")) {
        /* Nothing to answer: the code is ours to show and the remote does the typing. The sheet
         * stays up until Cancel, or until the shell sees the device paired. */
        gchar *code;
        if (g_str_equal(name, "DisplayPasskey")) {
            guint32 passkey = 0;
            guint16 entered = 0;
            g_variant_get(params, "(&ouq)", &dev, &passkey, &entered);
            code = g_strdup_printf("%06u", passkey);
        } else {
            const gchar *pin = NULL;
            g_variant_get(params, "(&o&s)", &dev, &pin);
            code = g_strdup(pin);
        }
        g_dbus_method_invocation_return_value(invocation, NULL);
        ask(NULL, "display", dev, code, NULL);
        g_free(code);
    } else if (g_str_equal(name, "Cancel")) {
        /* The remote or BlueZ gave up. Every open question goes, and the sheet with it. */
        GHashTableIter it;
        gpointer k, v;
        g_hash_table_iter_init(&it, asks);
        GString *s = g_string_new("");
        while (g_hash_table_iter_next(&it, &k, &v)) {
            Ask *a = v;
            if (a->invocation) {
                g_dbus_method_invocation_return_dbus_error(a->invocation, "org.bluez.Error.Canceled",
                                                           "The device cancelled");
                a->invocation = NULL;
            }
            g_string_printf(s, "{\"ev\":\"hide\",\"id\":%u}\n", a->id);
            to_shell(s->str);
        }
        g_string_free(s, TRUE);
        g_hash_table_remove_all(asks);
        g_dbus_method_invocation_return_value(invocation, NULL);
    } else {
        g_dbus_method_invocation_return_dbus_error(invocation, "org.bluez.Error.Rejected", "No");
    }
}

static const GDBusInterfaceVTable vtable = { method, NULL, NULL, { 0 } };

static void bluez_appeared(GDBusConnection *conn, const gchar *name, const gchar *owner, gpointer u) {
    GError *err = NULL;
    GVariant *r = g_dbus_connection_call_sync(
        conn, "org.bluez", "/org/bluez", "org.bluez.AgentManager1", "RegisterAgent",
        g_variant_new("(os)", AGENT_PATH, CAPABILITY), NULL,
        G_DBUS_CALL_FLAGS_NONE, 5000, NULL, &err);
    if (!r) {
        g_printerr("btagent: BlueZ refused the agent: %s\n", err->message);
        return;
    }
    g_variant_unref(r);
    /* Being the default agent is what makes BlueZ route a request started anywhere -- the remote
     * device, bluetoothctl -- to this sheet. Another agent may already hold it (blueman), and that
     * is not a reason to stop: this one still serves the pairings the shell itself starts. */
    r = g_dbus_connection_call_sync(conn, "org.bluez", "/org/bluez", "org.bluez.AgentManager1",
                                    "RequestDefaultAgent", g_variant_new("(o)", AGENT_PATH), NULL,
                                    G_DBUS_CALL_FLAGS_NONE, 5000, NULL, &err);
    if (r) g_variant_unref(r);
    else g_printerr("btagent: not the default agent: %s\n", err->message);
}

static void quit(int sig) { if (loop) g_main_loop_quit(loop); }

int main(void) {
    signal(SIGINT, quit);
    signal(SIGTERM, quit);

    GError *err = NULL;
    /* The system bus refuses a call from one user process to another, and BlueZ itself runs as
     * root, so on the real bus the agent's methods can only be exercised by BlueZ with a device
     * in hand. TACIT_BT_BUS=session exports the same object on the session bus and registers
     * nothing, which is how the round trip is tested (see README). */
    const gchar *which = g_getenv("TACIT_BT_BUS");
    gboolean testing = which && g_str_equal(which, "session");
    bus = g_bus_get_sync(testing ? G_BUS_TYPE_SESSION : G_BUS_TYPE_SYSTEM, NULL, &err);
    if (!bus) {
        g_printerr("btagent: no system bus: %s\n", err->message);
        return 1;
    }
    GDBusNodeInfo *node = g_dbus_node_info_new_for_xml(introspection, NULL);
    if (!g_dbus_connection_register_object(bus, AGENT_PATH, node->interfaces[0], &vtable,
                                          NULL, NULL, &err)) {
        g_printerr("btagent: cannot export the agent: %s\n", err->message);
        return 1;
    }

    asks = g_hash_table_new_full(g_direct_hash, g_direct_equal, NULL, ask_free);

    /* The socket comes up before the agent registers, so a pairing request cannot arrive while
     * there is nowhere to ask. A stale file from a killed instance is removed first. */
    const gchar *run = g_getenv("XDG_RUNTIME_DIR");
    if (!run || !*run) {
        g_printerr("btagent: no XDG_RUNTIME_DIR\n");
        return 1;
    }
    gchar *sock_path = g_build_filename(run, "bt-agent.sock", NULL);
    g_unlink(sock_path);
    GSocketService *svc = g_socket_service_new();
    GSocketAddress *addr = g_unix_socket_address_new(sock_path);
    if (!g_socket_listener_add_address(G_SOCKET_LISTENER(svc), addr, G_SOCKET_TYPE_STREAM,
                                      G_SOCKET_PROTOCOL_DEFAULT, NULL, NULL, &err)) {
        g_printerr("btagent: cannot listen on %s: %s\n", sock_path, err->message);
        return 1;
    }
    g_chmod(sock_path, 0600);
    g_signal_connect(svc, "incoming", G_CALLBACK(on_connect), NULL);
    g_socket_service_start(svc);

    if (testing) {
        loop = g_main_loop_new(NULL, FALSE);
        g_main_loop_run(loop);
        g_unlink(sock_path);
        g_free(sock_path);
        return 0;
    }

    /* BlueZ forgets its agents when bluetoothd exits, and may start after this process, so the
     * agent registers whenever the name appears, not once. */
    g_bus_watch_name_on_connection(bus, "org.bluez", G_BUS_NAME_WATCHER_FLAGS_NONE,
                                   bluez_appeared, NULL, NULL, NULL);

    loop = g_main_loop_new(NULL, FALSE);
    g_main_loop_run(loop);

    g_dbus_connection_call_sync(bus, "org.bluez", "/org/bluez", "org.bluez.AgentManager1",
                                "UnregisterAgent", g_variant_new("(o)", AGENT_PATH), NULL,
                                G_DBUS_CALL_FLAGS_NONE, 2000, NULL, NULL);
    g_unlink(sock_path);
    g_free(sock_path);
    return 0;
}
