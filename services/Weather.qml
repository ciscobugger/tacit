pragma Singleton
pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Io
import QtQuick
import QtPositioning

import qs.modules.common

Singleton {
    id: root

    // 10 minute
    readonly property int fetchInterval: Config.options.bar.weather.fetchInterval * 60 * 1000
    readonly property string city: Config.options.bar.weather.city
    readonly property bool useUSCS: Config.options.bar.weather.useUSCS
    readonly property bool gpsEnabled: Config.options.bar.weather.enableGPS
    // Set when GPS gave up; a separate flag so the Settings toggle binding stays intact.
    property bool gpsFailed: false
    readonly property bool gpsActive: root.gpsEnabled && !root.gpsFailed
    onGpsEnabledChanged: root.gpsFailed = false

    // Weather views on screen (the desktop widgets and the bar item count themselves in and out).
    // With none, or with no key, nothing is fetched and the location service is not started.
    property int viewers: 0
    readonly property bool keySet: (Config.options?.bar?.weather?.apiKey ?? "").length > 0
    readonly property bool wanted: root.viewers > 0 && root.keySet

    onUseUSCSChanged: root.getData()
    onCityChanged: root.getData()
    onKeySetChanged: root.getData()
    onViewersChanged: if (!root.keySet) root.getData()

    property var location: ({
        valid: false,
        lat: 0,
        lon: 0
    })

    // No key configured: weather has nothing to show and says why.
    property bool keyMissing: false
    // Why there is no reading. Every weather surface already renders data.city and
    // data.description, so the reason travels through those instead of a state of its own.
    property string failureReason: ""
    // The current-weather endpoint carries no precipitation probability; it comes from the
    // forecast endpoint's first block, and is unknown until that answers.
    property string rainChance: "--"
    property string fetchQuery: ""

    // Nothing read yet, or the last read failed. A dash beats a three-hour-old temperature
    // presented as the weather now.
    function blankData(cityText, descriptionText) {
        return {
            uv: 0,
            humidity: "--",
            sunrise: "--",
            sunset: "--",
            windDir: 0,
            wCode: 0,
            city: cityText,
            wind: "--",
            precip: "--",
            visib: "--",
            press: "--",
            temp: "--°",
            tempFeelsLike: "--°",
            cr: "--",
            description: descriptionText,
            lastRefresh: ""
        }
    }

    property var data: root.blankData("--", "")

    function reportFailure(reason) {
        root.failureReason = reason
        root.data = root.blankData(Translation.tr("Weather unavailable"), reason)
    }

    function refineData(data) {
        let temp = {}
        const rainMm = data?.rain?.["1h"] || data?.rain?.["3h"] || 0
        const snowMm = data?.snow?.["1h"] || data?.snow?.["3h"] || 0

        temp.description = data?.weather?.[0]?.description || ""
        temp.cr = root.rainChance
        temp.humidity = (data?.main?.humidity || 0) + "%"

        const fmt = (unix) => new Date(unix * 1000).toLocaleTimeString("en-US", {
            hour: "numeric",
            minute: "2-digit",
            second: "2-digit",
            hour12: true
        })

        temp.sunrise = data?.sys?.sunrise ? fmt(data.sys.sunrise) : "0"
        temp.sunset  = data?.sys?.sunset  ? fmt(data.sys.sunset)  : "0"

        temp.windDir = data?.wind?.deg || 0
        temp.wCode = data?.weather?.[0]?.id || 0
        temp.city = data?.name || "City"

        if (root.useUSCS) {
            temp.wind = (data?.wind?.speed || 0) + " mph"
            temp.precip = ((rainMm + snowMm) * 0.0394).toFixed(2) + " in"
            temp.visib = ((data?.visibility || 0) / 1609).toFixed(1) + " mi"
            temp.press = (data?.main?.pressure || 0) + " hPa"
            temp.temp = Math.round(data?.main?.temp || 0) + "°F"
            temp.tempFeelsLike = Math.round(data?.main?.feels_like || 0) + "°F"
        } else {
            temp.wind = (data?.wind?.speed || 0) + " m/s"
            temp.precip = (rainMm + snowMm).toFixed(1) + " mm"
            temp.visib = ((data?.visibility || 0) / 1000).toFixed(1) + " km"
            temp.press = (data?.main?.pressure || 0) + " hPa"
            let roundedTemp = Math.round(data?.main?.temp || 0)
            let roundedFeels = Math.round(data?.main?.feels_like || 0)

            temp.temp = roundedTemp + "°C"
            temp.tempFeelsLike = roundedFeels + "°C"
        }

        temp.lastRefresh = DateTime.time + " • " + DateTime.date

        root.data = temp
    }

    // --connect-timeout/--max-time: without them a captive portal or a blackholed route
    // parks curl forever, and every later tick then sets running on an already-running
    // Process, which is a no-op - the widget froze until the shell restarted.
    function curlFor(url) {
        return ["curl", "-s", "--connect-timeout", "5", "--max-time", "15", url]
    }

    function getData() {
        if (root.viewers <= 0)
            return
        // The key is the user's, not ours: an inherited key was hardcoded here, which both
        // leaks a credential when this repo is published and rate-limits every install that
        // shares it.
        const apiKey = Config.options?.bar?.weather?.apiKey ?? ""

        if (apiKey.length === 0) {
            root.keyMissing = true
            root.reportFailure(Translation.tr("No OpenWeather key: set weather.apiKey in the shell config"))
            return
        }
        root.keyMissing = false

        // The city is the floor, not the alternative: GPS coordinates are used only once a
        // fix has actually arrived, so a geoclue that never answers cannot leave the widget
        // empty for the whole session.
        let place = ""
        if (root.gpsActive && root.location.valid) {
            place = `lat=${root.location.lat}&lon=${root.location.lon}`
        } else if (root.city.trim().length > 0) {
            place = `q=${encodeURIComponent(root.city.trim())}`
        } else {
            root.reportFailure(Translation.tr("No GPS fix - set a city in Settings"))
            return
        }

        const units = root.useUSCS ? "imperial" : "metric"
        root.fetchQuery = `${place}&units=${units}&appid=${apiKey}`

        if (fetcher.running) {
            root.refetchPending = true
            return
        }
        fetcher.command = root.curlFor(`https://api.openweathermap.org/data/2.5/weather?${root.fetchQuery}`)
        fetcher.running = true
    }

    // A change that arrived while a request was in flight; fetched again once it exits.
    property bool refetchPending: false

    Process {
        id: fetcher
        onExited: {
            if (root.refetchPending) {
                root.refetchPending = false
                root.getData()
            }
        }
        stdout: StdioCollector {
            onStreamFinished: {
                if (text.length === 0) {
                    root.reportFailure(Translation.tr("Couldn't reach the weather service"))
                    return
                }

                try {
                    const parsedData = JSON.parse(text)

                    if (parsedData.cod && Number(parsedData.cod) !== 200) {
                        root.reportFailure(parsedData.message ?? Translation.tr("The weather service refused the request"))
                        return
                    }

                    root.failureReason = ""
                    root.refineData(parsedData)
                    root.getRainChance()
                } catch (e) {
                    root.reportFailure(Translation.tr("The weather service sent something unreadable"))
                }
            }
        }
    }

    function getRainChance() {
        if (popFetcher.running || root.fetchQuery.length === 0)
            return
        popFetcher.command = root.curlFor(`https://api.openweathermap.org/data/2.5/forecast?${root.fetchQuery}&cnt=1`)
        popFetcher.running = true
    }

    Process {
        id: popFetcher
        stdout: StdioCollector {
            onStreamFinished: {
                let pop = undefined
                try {
                    pop = JSON.parse(text)?.list?.[0]?.pop
                } catch (e) {
                    pop = undefined
                }
                root.rainChance = (pop === undefined || pop === null) ? "--" : Math.round(pop * 100) + "%"
                root.data = Object.assign({}, root.data, { "cr": root.rainChance })
            }
        }
    }

    // The location service exists only while weather is wanted and GPS is on: creating a
    // PositionSource loads the geoclue plugin, which contacts the location service.
    Loader {
        id: positionLoader
        active: root.wanted && root.gpsActive
        onActiveChanged: if (!positionLoader.active) gpsAcquisition.stop()
        onLoaded: {
            console.info("[WeatherService] Starting GPS service.")
            gpsAcquisition.restart()
        }
        // gpsActive turns false from inside these handlers, which would change this Loader's
        // own active binding while it is loading; hence callLater.
        sourceComponent: PositionSource {
            id: positionSource
            active: true
            updateInterval: root.fetchInterval

            onPositionChanged: {
                if (position.latitudeValid && position.longitudeValid) {
                    root.location.lat = position.coordinate.latitude
                    root.location.lon = position.coordinate.longitude
                    root.location.valid = true
                    gpsAcquisition.stop()
                    root.getData()
                } else {
                    Qt.callLater(() => root.gpsFailed = !root.location.valid)
                    console.error("[WeatherService] Failed to get GPS location.")
                }
            }

            onSourceErrorChanged: {
                if (positionSource.sourceError === PositionSource.NoError) return
                positionSource.stop()
                gpsAcquisition.stop()
                root.location.valid = false
                Qt.callLater(() => root.gpsFailed = true)
                console.error("[WeatherService] Position source error:", positionSource.sourceError)
                root.getData()
            }

            onValidityChanged: {
                if (!positionSource.valid) {
                    positionSource.stop()
                    gpsAcquisition.stop()
                    root.location.valid = false
                    Qt.callLater(() => root.gpsFailed = true)
                    console.error("[WeatherService] Could not acquire valid GPS backend.")
                }
            }
        }
    }

    // geoclue can accept the request and simply never answer (it denies agents it does not
    // know, and the plugin stays valid, so onValidityChanged never fires). Give up and let
    // the configured city carry it.
    Timer {
        id: gpsAcquisition
        interval: 30000
        onTriggered: {
            if (root.location.valid) return
            root.gpsFailed = true
            console.info("[WeatherService] No GPS fix in 30s, falling back to the configured city.")
            root.getData()
        }
    }

    Timer {
        running: root.wanted
        repeat: true
        interval: root.fetchInterval
        triggeredOnStart: true
        onTriggered: root.getData()
    }
}
