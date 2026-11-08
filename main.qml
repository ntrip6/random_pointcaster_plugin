import QtQuick
import QtQuick.Controls

import org.qfield
import org.qgis
import Theme

Item {
  id: plugin

  property var mainWindow: iface.mainWindow()
  property var mapCanvas: iface.mapCanvas()
  property int requestedPointCount: 1
  property var pendingTargets: []
  property bool extentDistanceUnavailable: false
  property string selectionSummary: ""
  property string runTime: ""
  property string projectFilePath: ""
  property var projectInfoItem: null
  property string generationError: ""

  Component.onCompleted: {
    log("Plugin loaded")
    iface.addItemToPluginsToolbar(pluginButton)
    log("Toolbar button registered")
    projectInfoItem = iface.findItemByObjectName("projectInfo")
    if (projectInfoItem && projectInfoItem.filePath) {
      projectFilePath = String(projectInfoItem.filePath)
      restoreTimer.restart()
    }
  }

  Connections {
    target: plugin.projectInfoItem
    ignoreUnknownSignals: true

    function onFilePathChanged() {
      if (!plugin.projectInfoItem.filePath) {
        restoreTimer.stop()
        plugin.projectFilePath = ""
        plugin.pendingTargets = []
      }
    }
  }

  Connections {
    target: iface
    ignoreUnknownSignals: true

    function onLoadProjectTriggered(path, name) {
      restoreTimer.stop()
      plugin.projectFilePath = ""
      plugin.pendingTargets = []
    }

    function onLoadProjectEnded(path, name) {
      plugin.projectFilePath = String(path)
      restoreTimer.restart()
    }
  }

  Timer {
    id: restoreTimer
    interval: 1
    repeat: false
    onTriggered: plugin.restoreProjectLayer()
  }

  QfToolButton {
    id: pluginButton
    iconSource: "icon.svg"
    iconColor: Theme.mainColor
    bgcolor: Theme.darkGray
    round: true

    onClicked: {
      log("Toolbar button clicked")
      // Capture the selection now; opening the dialog may clear it
      try {
        plugin.pendingTargets = plugin.collectTargets()
        plugin.extentDistanceUnavailable = plugin.isGeographicExtent(plugin.pendingTargets)
        plugin.selectionSummary = plugin.describeTargets(plugin.pendingTargets)
      } catch (e) {
        plugin.pendingTargets = []
        plugin.selectionSummary = ""
        log("ERROR capturing targets: " + e)
        mainWindow.displayToast(qsTr("Random Pointcaster: %1").arg(e))
        return
      }
      countDialog.open()
      log("Dialog open() called; visible=" + countDialog.visible)
    }
  }

  Dialog {
    id: generationErrorDialog
    title: qsTr("Random Pointcaster error")
    modal: true
    standardButtons: Dialog.Ok
    parent: mainWindow.contentItem
    anchors.centerIn: parent
    width: Math.min(parent.width * 0.9, 360)
    z: 10000

    contentItem: Label {
      width: generationErrorDialog.availableWidth
      wrapMode: Text.WordWrap
      text: plugin.generationError
    }
  }

  Dialog {
    id: fallbackWarningDialog
    title: qsTr("Points saved locally")
    modal: true
    standardButtons: Dialog.Ok
    parent: mainWindow.contentItem
    anchors.centerIn: parent
    width: Math.min(parent.width * 0.9, 360)
    z: 10000

    contentItem: Label {
      width: fallbackWarningDialog.availableWidth
      wrapMode: Text.WordWrap
      text: qsTr("Points are being saved to random_pointcaster.gpkg in this project folder. They will be included in an exported project ZIP, but will not be synchronized automatically to the original QGIS layer.")
    }
  }

  Dialog {
    id: countDialog
    title: qsTr("Generate Random Points")
    modal: true
    standardButtons: Dialog.Ok | Dialog.Cancel
    parent: mainWindow.contentItem
    anchors.centerIn: parent
    width: Math.min(parent.width * 0.9, 360)
    z: 10000

    contentItem: Column {
      spacing: 12

      width: countDialog.availableWidth

      Label {
        width: parent.width
        wrapMode: Text.WordWrap
        text: plugin.selectionSummary
      }

      ComboBox {
        id: modeBox
        width: parent.width
        model: [qsTr("Number of points per feature"),
                qsTr("Density (per 1,000 m\u00b2 or per 100 m of line)")]
      }

      SpinBox {
        id: pointCount
        visible: modeBox.currentIndex === 0
        from: 1
        to: 5000
        value: plugin.requestedPointCount
        editable: true
      }

      TextField {
        id: densityField
        visible: modeBox.currentIndex === 1
        width: parent.width
        text: "1"
        placeholderText: qsTr("Points per 1,000 m\u00b2 / per 100 m")
        inputMethodHints: Qt.ImhFormattedNumbersOnly
      }

      Label {
        text: qsTr("Minimum distance between points (m, 0 = off)")
        width: parent.width
        wrapMode: Text.WordWrap
      }

      SpinBox {
        id: minDistance
        enabled: !plugin.extentDistanceUnavailable
        from: 0
        to: 10000
        value: 0
        editable: true
      }

      Label {
        visible: plugin.extentDistanceUnavailable
        width: parent.width
        wrapMode: Text.WordWrap
        text: qsTr("Minimum distance is unavailable for map extent sampling in a geographic CRS.")
      }
    }

    onAccepted: {
      let density = parseFloat(String(densityField.text).replace(",", "."))
      let options = {
        mode: modeBox.currentIndex === 1 ? "density" : "count",
        count: pointCount.value,
        density: isNaN(density) ? 0 : density,
        minDistance: minDistance.enabled ? minDistance.value : 0
      }
      plugin.requestedPointCount = pointCount.value
      log("Generation requested: " + JSON.stringify(options))
      plugin.generatePoints(options)
    }
  }

  // Newer QField prefixes helpers with "Qf"; older builds use the bare names.
  // typeof is safe on undeclared identifiers, unlike a direct reference.
  readonly property var geometryUtils: typeof QfGeometryUtils !== "undefined"
      ? QfGeometryUtils : (typeof GeometryUtils !== "undefined" ? GeometryUtils : null)
  readonly property var layerUtils: typeof QfLayerUtils !== "undefined"
      ? QfLayerUtils : (typeof LayerUtils !== "undefined" ? LayerUtils : null)
  readonly property var featureUtils: typeof QfFeatureUtils !== "undefined"
      ? QfFeatureUtils : (typeof FeatureUtils !== "undefined" ? FeatureUtils : null)
  readonly property var projectUtils: typeof QfProjectUtils !== "undefined"
      ? QfProjectUtils : (typeof ProjectUtils !== "undefined" ? ProjectUtils : null)
  readonly property var fileUtils: typeof QfFileUtils !== "undefined"
      ? QfFileUtils : (typeof FileUtils !== "undefined" ? FileUtils : null)

  function log(message) {
    console.warn("[Random Pointcaster] " + message)
  }

  // QML exposes some QGIS members as properties and others as methods
  function get(obj, name) {
    let member = obj[name]
    return typeof member === "function" ? obj[name]() : member
  }

  function generatePoints(options) {
    try {
      generatePointsUnsafe(options)
    } catch (e) {
      log("ERROR: " + e)
      generationError = String(e)
      generationErrorDialog.open()
    }
  }

  // Points for one target: fixed count, or density x size
  // (per 1,000 m2 for polygons, per 100 m for lines)
  function pointsForTarget(target, options) {
    if (options.mode !== "density") {
      return options.count
    }
    if (!target.size || !(options.density > 0)) {
      return 0
    }
    let unit = target.kind === "line" ? 100 : 1000
    return Math.max(1, Math.round(target.size / unit * options.density))
  }

  function generatePointsUnsafe(options) {
    log("Starting point generation; helpers: geometry=" + (geometryUtils ? "ok" : "MISSING")
        + ", layer=" + (layerUtils ? "ok" : "MISSING")
        + ", project=" + (projectUtils ? "ok" : "MISSING"))
    if (!geometryUtils || !layerUtils || !projectUtils) {
      mainWindow.displayToast(qsTr("Random Pointcaster: this QField version lacks required helpers."))
      return
    }
    let targets = pendingTargets
    pendingTargets = []
    if (!targets || targets.length === 0) {
      targets = collectTargets()
    }
    if (!targets || targets.length === 0) {
      log("Failed: no targets")
      mainWindow.displayToast(qsTr("No valid polygon, line or map extent is available."))
      return
    }
    validateTargets(targets)
    if (isGeographicExtent(targets)) {
      options.minDistance = 0
    }

    let outCrs = targets[0].crs
    let attrs = createRunMetadata(targets.length === 1 ? targets[0].name : qsTr("Multiple features"),
                                  0, options.minDistance, options.mode)
    runTime = timeLabel(new Date(attrs.runCreated))
    let outCrsId = get(outCrs, "authid")
    let points = []
    let overlapping = false
    let requested = 0
    let placedByCrs = {}
    for (let t = 0; t < targets.length; t++) {
      let target = targets[t]
      let pointCount = pointsForTarget(target, options)
      requested += pointCount
      let crsKey = get(target.crs, "authid")
      if (!placedByCrs[crsKey]) {
        placedByCrs[crsKey] = []
      }
      let generated = pointCount > 0
          ? sampleTarget(target, pointCount, placedByCrs[crsKey], options.minDistance) : []
      log("Target " + target.name + " (" + target.kind + "): " + generated.length
          + " of " + pointCount + " points")
      if (!overlapping && target.kind === "polygon") {
        overlapping = fallsInOtherPolygon(generated, targets, t)
      }
      let rate = (target.size && generated.length > 0) ? generated.length / target.size * 100 : null
      let sameCrs = get(target.crs, "authid") === outCrsId
      for (let i = 0; i < generated.length; i++) {
        let p = generated[i]
        if (!sameCrs) {
          p = reprojectPoint(p, target.crs, outCrs)
        }
        points.push({
          x: p.x, y: p.y,
          name: labelWithSuffix(target.name, " Sample " + (i + 1) + " " + runTime, 100),
          featureId: target.id,
          rate: rate,
          created: new Date()
        })
      }
    }

    if (points.length === 0) {
      log("Failed: generated 0 points")
      mainWindow.displayToast(options.mode === "density" && requested === 0
          ? qsTr("Density needs a positive value and a feature with a known size.")
          : qsTr("No points could be generated on the selected features."))
      return
    }

    attrs.requested = requested
    attrs.generated = points.length
    if (!addOutputLayer(points, { crs: outCrs }, attrs)) {
      log("Failed: output layer creation did not complete")
      return
    }

    let message = qsTr("Created %1 random points").arg(points.length)
    if (points.length < requested) {
      message += options.minDistance > 0
          ? qsTr(" (requested %1; minimum distance too large for the rest)").arg(requested)
          : qsTr(" (requested %1)").arg(requested)
      log("Partial result: requested " + requested + ", generated " + points.length)
    }
    mainWindow.displayToast(message)
    if (overlapping) {
      log("Overlap detected between selected polygons")
      mainWindow.displayToast(qsTr("Some selected polygons overlap, so the overlapping areas are sampled more than once."))
    }
    log("Completed: " + points.length + " points added")
  }

  // True if any point lies inside another selected polygon of the same CRS.
  // Only detects overlap that the sampled points happen to land in.
  function fallsInOtherPolygon(generated, targets, self) {
    let crsId = get(targets[self].crs, "authid")
    for (let o = 0; o < targets.length; o++) {
      let other = targets[o]
      if (o === self || other.kind !== "polygon" || get(other.crs, "authid") !== crsId) {
        continue
      }
      for (let i = 0; i < generated.length; i++) {
        let candidate = geometryUtils.createGeometryFromWkt(
            "POINT(" + generated[i].x + " " + generated[i].y + ")")
        if (geometryUtils.geometryWithin(candidate, other.geometry)) {
          return true
        }
      }
    }
    return false
  }

  function reprojectPoint(p, fromCrs, toCrs) {
    let g = geometryUtils.createGeometryFromWkt("POINT(" + p.x + " " + p.y + ")")
    let r = geometryUtils.reprojectGeometry(g, fromCrs, toCrs)
    let m = String(get(r, "asWkt")).match(/\(\s*(\S+)\s+(\S+)\s*\)/)
    if (!m) {
      throw new Error("reprojection failed")
    }
    return { x: parseFloat(m[1]), y: parseFloat(m[2]) }
  }

  // Random points inside a polygon (or the map extent), by rejection sampling
  // True if (x, y) is within minDistance of any point already placed in this run
  function tooClose(x, y, placed, minDistance) {
    if (!(minDistance > 0)) {
      return false
    }
    let limit = minDistance * minDistance
    for (let i = 0; i < placed.length; i++) {
      let dx = placed[i].x - x
      let dy = placed[i].y - y
      if (dx * dx + dy * dy < limit) {
        return true
      }
    }
    return false
  }

  function samplePolygon(target, pointCount, placed, minDistance) {
    let bounds = geometryUtils.boundingBox(target.geometry)
    let xMin = get(bounds, "xMinimum")
    let xMax = get(bounds, "xMaximum")
    let yMin = get(bounds, "yMinimum")
    let yMax = get(bounds, "yMaximum")
    let points = []
    let attempts = 0
    let maxAttempts = pointCount * 200
    while (points.length < pointCount && attempts < maxAttempts) {
      attempts += 1
      let x = xMin + Math.random() * (xMax - xMin)
      let y = yMin + Math.random() * (yMax - yMin)
      if (tooClose(x, y, placed, minDistance)) {
        continue
      }
      if (target.kind !== "extent") {
        let candidate = geometryUtils.createGeometryFromWkt("POINT(" + x + " " + y + ")")
        if (!geometryUtils.geometryWithin(candidate, target.geometry)) {
          continue
        }
      }
      points.push({ x: x, y: y })
      placed.push({ x: x, y: y })
    }
    return points
  }

  // Random points at uniformly random distances along a (multi)line,
  // returned in order along the line
  function sampleLine(target, pointCount, placed, minDistance) {
    let parts = linePartsFromWkt(get(target.geometry, "asWkt"))
    let segments = []
    let total = 0
    for (let p = 0; p < parts.length; p++) {
      for (let i = 0; i < parts[p].length - 1; i++) {
        let a = parts[p][i]
        let b = parts[p][i + 1]
        let length = Math.hypot(b[0] - a[0], b[1] - a[1])
        if (length > 0) {
          segments.push({ a: a, b: b, start: total, length: length })
          total += length
        }
      }
    }
    if (segments.length === 0) {
      return []
    }
    let accepted = []
    let attempts = 0
    let maxAttempts = pointCount * 200
    while (accepted.length < pointCount && attempts < maxAttempts) {
      attempts += 1
      let d = Math.random() * total
      let s = 0
      while (s < segments.length - 1 && d > segments[s].start + segments[s].length) {
        s++
      }
      let seg = segments[s]
      let f = Math.min(1, (d - seg.start) / seg.length)
      let x = seg.a[0] + f * (seg.b[0] - seg.a[0])
      let y = seg.a[1] + f * (seg.b[1] - seg.a[1])
      if (tooClose(x, y, placed, minDistance)) {
        continue
      }
      accepted.push({ d: d, x: x, y: y })
      placed.push({ x: x, y: y })
    }
    accepted.sort(function(m, n) { return m.d - n.d })
    return accepted.map(function(a) { return { x: a.x, y: a.y } })
  }

  function sampleTarget(target, pointCount, placed, minDistance) {
    return target.kind === "line" ? sampleLine(target, pointCount, placed, minDistance)
                                  : samplePolygon(target, pointCount, placed, minDistance)
  }

  // Vertex lists [[x, y], ...] for each part of a LineString / MultiLineString WKT
  function linePartsFromWkt(wkt) {
    if (typeof wkt !== "string") {
      return []
    }
    let groups = wkt.match(/\(([^()]+)\)/g) || []
    return groups.map(function(g) {
      return g.slice(1, -1).split(",").map(function(pt) {
        let c = pt.trim().split(/\s+/)
        return [parseFloat(c[0]), parseFloat(c[1])]
      })
    }).filter(function(pts) { return pts.length >= 2 })
  }

  // Line length in m; assumes a projected CRS with metre units
  function lengthMeters(geometry) {
    return attempt("length", function() {
      let parts = linePartsFromWkt(get(geometry, "asWkt"))
      let total = 0
      for (let p = 0; p < parts.length; p++) {
        for (let i = 0; i < parts[p].length - 1; i++) {
          total += Math.hypot(parts[p][i + 1][0] - parts[p][i][0],
                              parts[p][i + 1][1] - parts[p][i][1])
        }
      }
      return total > 0 ? total : null
    })
  }

  function formatSize(target) {
    if (!target.size) {
      return ""
    }
    let value = target.kind === "line" ? Math.round(target.size * 10) / 10
                                       : Math.round(target.size)
    return " (" + value + (target.kind === "line" ? " m)" : " m\u00b2)")
  }

  function describeTargets(targets) {
    if (!targets || targets.length === 0) {
      return qsTr("Nothing selected. Number of points to generate:")
    }
    if (targets[0].kind === "extent") {
      return qsTr("No polygon or line selected; points will be placed in the visible map extent. Number of points to generate:")
    }
    let shown = targets.slice(0, 6).map(function(t) { return t.name + formatSize(t) })
    let list
    if (targets.length > shown.length) {
      list = shown.join(", ") + qsTr(" and %1 more").arg(targets.length - shown.length)
    } else if (shown.length > 1) {
      list = shown.slice(0, -1).join(", ") + qsTr(" and ") + shown[shown.length - 1]
    } else {
      list = shown[0]
    }
    return targets.length > 1
        ? qsTr("You have selected %1. How many points in each feature?").arg(list)
        : qsTr("You have selected %1. How many points?").arg(list)
  }

  // Feature list model roles (Qt::UserRole = 256): Feature=260, Layer=262, Geometry=263, Selected=258
  property string lastError: ""

  // layerCrs() is missing in some QField builds; fall back to the layer's own crs
  function layerCrs(layer) {
    if (layerUtils && typeof layerUtils.layerCrs === "function") {
      return layerUtils.layerCrs(layer)
    }
    return get(layer, "crs")
  }

  // Runs fn, logging and remembering any exception so it can be shown to the user
  function attempt(name, fn) {
    try {
      return fn()
    } catch (e) {
      lastError = name + ": " + e
      log("ERROR in " + name + ": " + e)
      return null
    }
  }

  // "line" or "polygon" for supported features, otherwise null. The layer's geometry
  // type is preferred; the geometry's WKT is the fallback when it can't be read.
  function kindOf(layer, geometry) {
    let type = attempt("geometryType", function() { return get(layer, "geometryType") })
    if (type == 1) {
      return "line"
    }
    if (type == 2) {
      return "polygon"
    }
    if (type == 0) {
      return null
    }
    let wkt = attempt("asWkt", function() { return String(get(geometry, "asWkt")) })
    if (wkt && /^\s*(Multi)?(LineString|CompoundCurve|CircularString)/i.test(wkt)) {
      return "line"
    }
    if (wkt && /^\s*(Multi)?(Polygon|CurvePolygon)/i.test(wkt)) {
      return "polygon"
    }
    return null
  }

  function isGeographicExtent(targets) {
    if (!targets || targets.length !== 1 || targets[0].kind !== "extent") {
      return false
    }
    let crs = targets[0].crs
    let geographic = crs ? get(crs, "isGeographic") : undefined
    if (typeof geographic !== "boolean") {
      throw new Error(qsTr("Cannot determine whether the map CRS is geographic."))
    }
    return geographic
  }

  function validateTargets(targets) {
    for (let i = 0; i < targets.length; i++) {
      if (targets[i].kind === "curved") {
        throw new Error(qsTr("Curved geometries are not supported. Convert the selected features to straight segments before sampling."))
      }
    }
  }

  // Builds a sampling target from a layer/feature/geometry, or null if unsupported
  function makeTarget(layer, feature, geometry) {
    if (!layer || !feature || !geometry || get(geometry, "isEmpty")) {
      return null
    }
    let wkt = get(geometry, "asWkt")
    if (typeof wkt !== "string") {
      throw new Error(qsTr("Could not inspect the selected feature's geometry."))
    }
    if (/\b(CircularString|CompoundCurve|CurvePolygon|MultiCurve|MultiSurface)\b/i.test(wkt)) {
      return { kind: "curved" }
    }
    let kind = kindOf(layer, geometry)
    if (!kind) {
      return null
    }
    let size = kind === "line" ? lengthMeters(geometry) : areaSquareMeters(geometry)
    let id = feature.id
    let name = polygonNameOf(feature, layer)
    return {
      kind: kind,
      layer: layer,
      geometry: geometry,
      crs: layerCrs(layer),
      id: id,
      name: name ? name : (kind === "line" ? "Line " : "Polygon ") + id,
      size: size
    }
  }

  // Checked rows of the feature list model; if none are checked, every polygon and
  // line row (e.g. all features found under a single tap)
  function targetsFromModel(model) {
    let count = model.count
    let selected = []
    let all = []
    for (let i = 0; i < count; i++) {
      let index = model.index(i, 0)
      let target = makeTarget(model.data(index, 262), model.data(index, 260),
                              model.data(index, 263))
      if (!target) {
        continue
      }
      all.push(target)
      if (model.data(index, 258)) {
        selected.push(target)
      }
    }
    return selected.length > 0 ? selected : all
  }

  function findSelectedTargets() {
    let featureForm = iface.findItemByObjectName("featureForm")
    log("featureForm=" + (featureForm ? "found" : "null"))
    if (!featureForm) {
      return []
    }

    let selection = attempt("read selection", function() { return featureForm.selection })
    let model = attempt("read model", function() { return featureForm.model })
    log("selection=" + (selection ? "found" : "null")
        + "; model=" + (model ? "found" : "null"))

    let fromModel = []
    if (model) {
      log("model.count=" + model.count + "; model.selectedCount=" + model.selectedCount)
      fromModel = targetsFromModel(model)
    }
    validateTargets(fromModel)
    // Several features are only visible through the model; a single one may also be focused
    if (fromModel.length > 1) {
      return fromModel
    }

    let focused = null
    if (selection && selection.focusedLayer && selection.focusedFeature) {
      log("Source (focused): layer=" + selection.focusedLayer.name)
      focused = makeTarget(selection.focusedLayer, selection.focusedFeature,
                           selection.focusedGeometry)
    }
    if (focused) {
      return [focused]
    }
    return fromModel
  }

  // Value of the polygon's first non-empty "Name", "Label" or "Title" field
  // (case-insensitive, in that priority order), or null
  function polygonNameOf(feature, layer) {
    return attempt("polygon name", function() {
      let names = get(get(layer, "fields"), "names")
      let candidates = ["name", "label", "title"]
      for (let c = 0; c < candidates.length; c++) {
        let index = -1
        for (let i = 0; names && i < names.length; i++) {
          if (String(names[i]).toLowerCase() === candidates[c]) {
            index = i
            break
          }
        }
        if (index < 0) {
          continue
        }
        let value
        if (typeof feature.attribute === "function") {
          value = feature.attribute(names[index])
        }
        if (value === undefined || value === null) {
          let attributes = get(feature, "attributes")
          value = attributes ? attributes[index] : null
        }
        log("Polygon " + names[index] + " = " + value)
        if (value !== undefined && value !== null && String(value) !== "") {
          return String(value)
        }
      }
      log("No Name/Label/Title value found; fields=" + names)
      return null
    })
  }

  function collectTargets() {
    lastError = ""
    let found = findSelectedTargets()
    if (found.length > 0) {
      validateTargets(found)
      log("Using " + found.length + " selected feature(s)")
      return found
    }
    log("No selected polygon or line found")
    mainWindow.displayToast(lastError
        ? qsTr("Random Pointcaster: %1 (using map extent)").arg(lastError)
        : qsTr("Random Pointcaster: no polygon or line found, using map extent"))
    let settings = mapCanvas.mapSettings
    let extent = settings.visibleExtent
    let x1 = get(extent, "xMinimum")
    let x2 = get(extent, "xMaximum")
    let y1 = get(extent, "yMinimum")
    let y2 = get(extent, "yMaximum")
    log("Using visible map extent")
    return [{
      kind: "extent",
      geometry: geometryUtils.createGeometryFromWkt(
        "POLYGON((" + x1 + " " + y1 + "," + x2 + " " + y1 + "," + x2 + " " + y2
        + "," + x1 + " " + y2 + "," + x1 + " " + y1 + "))"),
      crs: settings.destinationCrs,
      id: null,
      name: "Map extent",
      size: null
    }]
  }

  function layerName() {
    return "Sample Points"
  }

  function labelWithSuffix(prefix, suffix, maxLength) {
    return String(prefix).slice(0, Math.max(0, maxLength - suffix.length)) + suffix
  }

  function pad2(n) {
    return (n < 10 ? "0" : "") + n
  }

  function timeLabel(date) {
    return pad2(date.getHours()) + ":" + pad2(date.getMinutes()) + ":" + pad2(date.getSeconds())
  }

  function createRunMetadata(targetName, requested, minDistance, mode) {
    let iso = new Date().toISOString()
    let compact = iso.replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z")
    let suffix = (Math.random().toString(36).substring(2, 6) + "0000").slice(0, 4)
    return {
      runId: compact + "-" + suffix,
      runCreated: iso,
      runName: labelWithSuffix(targetName, " - " + iso.substring(0, 16).replace("T", " "), 50),
      requested: requested,
      generated: 0,
      minDistance: minDistance,
      mode: mode
    }
  }

  // Polygon area in m2; assumes a projected CRS with metre units
  function areaSquareMeters(geometry) {
    return attempt("area", function() {
      let area = get(geometry, "area")
      if (!(typeof area === "number" && isFinite(area) && area > 0)) {
        log("geometry.area unavailable (" + area + "); computing from WKT")
        area = areaFromWkt(get(geometry, "asWkt"))
      }
      log("Polygon area = " + area + " m2")
      return (typeof area === "number" && isFinite(area) && area > 0) ? area : null
    })
  }

  // Shoelace area for (Multi)Polygon WKT: outer rings added, holes subtracted
  function areaFromWkt(wkt) {
    if (typeof wkt !== "string") {
      log("asWkt unavailable: " + wkt)
      return null
    }
    let rings = wkt.match(/\(([^()]+)\)/g)
    if (!rings) {
      return null
    }
    let total = 0
    let pending = wkt.replace(/\(([^()]+)\)/g, "R")
    let order = pending.match(/\(*R(?:,R)*\)*/g) || []
    let ringIndex = 0
    for (let g = 0; g < order.length; g++) {
      let count = (order[g].match(/R/g) || []).length
      for (let k = 0; k < count; k++, ringIndex++) {
        let pts = rings[ringIndex].replace(/[()]/g, "").split(",")
        let sum = 0
        for (let i = 0; i < pts.length - 1; i++) {
          let a = pts[i].trim().split(/\s+/)
          let b = pts[i + 1].trim().split(/\s+/)
          sum += a[0] * b[1] - b[0] * a[1]
        }
        let ringArea = Math.abs(sum) / 2
        total += (k === 0) ? ringArea : -ringArea
      }
    }
    return total
  }

  function fillLayer(layer, points, attrs) {
    let names = ["RunID", "RunName", "RunCreated", "Name", "InFeature",
                 "Created", "RunSamplingPct", "Requested", "Generated", "MinDistance", "Mode"]
    let indexes = {}
    let missing = []
    for (let i = 0; i < names.length; i++) {
      indexes[names[i]] = layer.fields.indexOf(names[i])
      if (indexes[names[i]] < 0) {
        missing.push(names[i])
      }
    }
    if (missing.length) {
      throw new Error("Sample Points layer is missing fields: " + missing.join(", ")
          + ". Update its schema before generating points.")
    }
    if (!featureUtils) {
      throw new Error("Feature helper is unavailable.")
    }
    for (let i = 0; i < points.length; i++) {
      let geometry = geometryUtils.createGeometryFromWkt(
          "POINT(" + points[i].x + " " + points[i].y + ")")
      let feature = featureUtils.createBlankFeature(layer.fields, geometry)
      feature.setAttribute(indexes.RunID, attrs.runId)
      feature.setAttribute(indexes.RunName, attrs.runName)
      feature.setAttribute(indexes.RunCreated, new Date(attrs.runCreated))
      feature.setAttribute(indexes.Name, points[i].name)
      if (points[i].featureId !== null) {
        feature.setAttribute(indexes.InFeature, points[i].featureId)
      }
      feature.setAttribute(indexes.Created, points[i].created)
      if (points[i].rate !== null) {
        feature.setAttribute(indexes.RunSamplingPct, points[i].rate)
      }
      feature.setAttribute(indexes.Requested, attrs.requested)
      feature.setAttribute(indexes.Generated, attrs.generated)
      feature.setAttribute(indexes.MinDistance, attrs.minDistance)
      feature.setAttribute(indexes.Mode, attrs.mode)
      if (!layerUtils.addFeature(layer, feature)) {
        throw new Error("Could not add point " + (i + 1) + " of " + points.length
            + "; earlier points from this run may already have been added.")
      }
    }
    return true
  }

  function createTypedLayer(points, crs, attrs) {
    if (!featureUtils) {
      throw new Error("Feature helper is unavailable in this QField version.")
    }
    let uri = "Point?crs=" + get(crs, "authid")
        + "&field=RunID:string(36)&field=RunName:string(50)&field=RunCreated:datetime"
        + "&field=Name:string(100)&field=InFeature:int8"
        + "&field=Created:datetime&field=RunSamplingPct:double"
        + "&field=Requested:int8&field=Generated:int8"
        + "&field=MinDistance:double&field=Mode:string(10)"
    let layer = layerUtils.loadVectorLayer(uri, layerName(), "memory")
    if (!layer || !get(layer, "isValid")) {
      throw new Error("Could not create the temporary point layer (CRS: "
                      + get(crs, "authid") + ").")
    }
    fillLayer(layer, points, attrs)
    return layer
  }

  readonly property string gpkgFileName: "random_pointcaster.gpkg"

  function projectGeoPackagePath() {
    if (!projectFilePath) {
      throw new Error("Open a saved project before generating points.")
    }
    if (!fileUtils || typeof fileUtils.fileExists !== "function"
        || typeof fileUtils.absolutePath !== "function") {
      throw new Error("This QField version lacks the file utilities needed for safe project storage.")
    }
    let folder = fileUtils.absolutePath(projectFilePath)
    if (!folder) {
      throw new Error("The current project folder could not be determined.")
    }
    return String(folder).replace(/\\/g, "/").replace(/\/+$/, "") + "/" + gpkgFileName
  }

  function loadSavedLayer(path) {
    let layer = layerUtils.loadVectorLayer(path, layerName(), "ogr")
    if (!layer || !get(layer, "isValid") || get(layer, "geometryType") !== 0) {
      throw new Error("Cannot open the existing point GeoPackage: " + path
          + ". It was not overwritten.")
    }
    return layer
  }

  function restoreProjectLayer() {
    try {
      let path = projectGeoPackagePath()
      if (!fileUtils.fileExists(path) || layerAlreadyInProject(path)) {
        return
      }
      if (findProjectSampleLayer()) {
        throw new Error("A different Sample Points layer is already in this project. "
                        + "The saved file was not loaded: " + path)
      }
      let layer = loadSavedLayer(path)
      if (!projectUtils.addMapLayer(qgisProject, layer)) {
        throw new Error("Could not reload the saved Sample Points layer: " + path)
      }
      log("Restored Sample Points from " + path)
    } catch (e) {
      log("ERROR restoring points: " + e)
      mainWindow.displayToast(qsTr("Random Pointcaster: %1").arg(e))
    }
  }

  function layerAlreadyInProject(path) {
    let found = qgisProject.mapLayersByName(layerName())
    for (let i = 0; found && i < found.length; i++) {
      if (layerUsesPath(found[i], path)) {
        return true
      }
    }
    return false
  }

  function layerUsesPath(layer, path) {
    let source = String(get(layer, "source")).split("|")[0]
    return source.replace(/\\/g, "/") === path
  }

  // Finds a point layer named "Sample Points" that is already part of the project
  function findProjectSampleLayer() {
    let found = qgisProject.mapLayersByName(layerName())
    for (let i = 0; found && i < found.length; i++) {
      let layer = found[i]
      if (get(layer, "isValid") && get(layer, "geometryType") === 0) {
        return layer
      }
    }
    return null
  }

  // Adds the points straight into the project's own layer so that QFieldCloud /
  // QFieldSync see them as ordinary edits
  function appendToProjectLayer(layer, points, target, attrs) {
    let layerCrsId = get(layerCrs(layer), "authid")
    let sourceCrsId = get(target.crs, "authid")
    let pts = points
    if (layerCrsId && sourceCrsId && layerCrsId !== sourceCrsId) {
      log("Reprojecting points " + sourceCrsId + " -> " + layerCrsId)
      pts = points.map(function(p) {
        let q = reprojectPoint(p, target.crs, layerCrs(layer))
        return { x: q.x, y: q.y, name: p.name, featureId: p.featureId, rate: p.rate,
                 created: p.created }
      })
    }
    let before = get(layer, "featureCount")
    fillLayer(layer, pts, attrs)
    log("Appended to project layer; featureCount " + before + " -> " + get(layer, "featureCount"))
    return true
  }

  function addOutputLayer(points, target, attrs) {
    log("Creating output layer")
    log("Points=" + points.length)

    let path = projectGeoPackagePath()
    let savedExists = fileUtils.fileExists(path)
    let projectLayer = findProjectSampleLayer()
    if (projectLayer) {
      if (savedExists && !layerUsesPath(projectLayer, path)) {
        throw new Error("A different Sample Points layer is already in this project. "
                        + "Resolve the conflict with " + path + " before generating points.")
      }
      if (appendToProjectLayer(projectLayer, points, target, attrs)) {
        attempt("repaint", function() { projectLayer.triggerRepaint() })
        mainWindow.displayToast(qsTr("Added %1 points to the project's Sample Points layer").arg(points.length))
        if (layerUsesPath(projectLayer, path)) {
          fallbackWarningDialog.open()
        }
        return true
      }
      return false
    }

    let layer
    if (savedExists) {
      layer = loadSavedLayer(path)
      appendToProjectLayer(layer, points, target, attrs)
      mainWindow.displayToast(qsTr("Added %1 points to %2").arg(points.length).arg(gpkgFileName))
    } else {
      layer = createTypedLayer(points, target.crs, attrs)
      if (fileUtils.fileExists(path)) {
        throw new Error("The destination appeared while generating points; it was not overwritten: " + path)
      }
      if (typeof layerUtils.saveVectorLayerAs !== "function") {
        throw new Error("This QField version cannot save the Sample Points GeoPackage.")
      }
      let result = layerUtils.saveVectorLayerAs(layer, path, "GPKG")
      if (!result) {
        throw new Error("Could not save Sample Points to the project folder: " + path)
      }
      layer = loadSavedLayer(result)
      mainWindow.displayToast(qsTr("Points saved to %1").arg(result))
    }

    if (!projectUtils.addMapLayer(qgisProject, layer)) {
      log("Failed: addMapLayer returned false")
      mainWindow.displayToast(qsTr("Points were saved, but the layer could not be added to the project: %1").arg(path))
      return false
    }
    log("Output layer added to project")
    fallbackWarningDialog.open()
    return true
  }
}
