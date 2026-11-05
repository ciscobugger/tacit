# Mail reference style for Tacit.Kit

This portable patch modifies the existing Slab, Field and TextArea implementations. The mail UI keeps importing Tacit.Kit and uses the same public API. It introduces no replacement controls or Mac-specific imports.

- Slab: the default safe action is a filled accent pill with on-accent words; quiet/risk/confirmation controls retain their existing behavior.
- Field: flat, compact text with a subtle bottom rule and a hover wash, instead of a boxed field.
- TextArea: document text with no boxed background and the body type size. Native editing, selection, caret, scrolling and submission remain in the component.
- Fields and text areas retain their focus ring for keyboard navigation and errors. A pointer click leaves the caret visible without adding a large ring around the document.

The ignored Mac adapter copies the sibling Kit, applies this patch, then applies only the local platform compatibility adaptations. The sibling Kit source is never modified by the preview build. Building again always starts from the original Kit, so changes do not accumulate.

For a future Linux prototype, apply this patch to an isolated Kit checkout or staging copy before configuring its QML import path:

```sh
patch --dry-run -F 0 -p1 -d /path/to/staged/Tacit/Kit -i /absolute/path/to/mail/kit-style/reference.patch
patch -F 0 -p1 -d /path/to/staged/Tacit/Kit -i /absolute/path/to/mail/kit-style/reference.patch
```

This is an app-specific design proposal, not an upstream Kit change. Without the patch, the frontend remains runnable against the stock Kit but has stock control styling. If the Kit changes and the patch fails, review it against the new component sources; do not silently skip it.
