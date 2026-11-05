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
  property string selectionSummary: ""

  Component.onCompleted: {
    log("Plugin loaded")
    iface.addItemToPluginsToolbar(pluginButton)
    log("Toolbar button registered")
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
        plugin.selectionSummary = plugin.describeTargets(plugin.pendingTargets)
      } catch (e) {
        plugin.pendingTargets = []
        plugin.selectionSummary = ""
        log("ERROR capturing targets: " + e)
      }
      countDialog.open()
      log("Dialog open() called; visible=" + countDialog.visible)
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

      SpinBox {
        id: pointCount
        from: 1
        to: 5000
        value: plugin.requestedPointCount
        editable: true
      }
    }

    onAccepted: {
      plugin.requestedPointCount = pointCount.value
      log("Generation requested for " + pointCount.value + " points")
      plugin.generatePoints(pointCount.value)
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

  function log(message) {
    console.warn("[Random Pointcaster] " + message)
  }

  // QML exposes some QGIS members as properties and others as methods
  function get(obj, name) {
    let member = obj[name]
    return typeof member === "function" ? obj[name]() : member
  }

  function generatePoints(pointCount) {
    try {
      generatePointsUnsafe(pointCount)
    } catch (e) {
      log("ERROR: " + e)
      mainWindow.displayToast(qsTr("Random Pointcaster error: %1").arg(e))
    }
  }

  function generatePointsUnsafe(pointCount) {
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

    let outCrs = targets[0].crs
    let outCrsId = get(outCrs, "authid")
    let points = []
    for (let t = 0; t < targets.length; t++) {
      let target = targets[t]
      let generated = sampleTarget(target, pointCount)
      log("Target " + target.name + " (" + target.kind + "): " + generated.length
          + " of " + pointCount + " points")
      let rate = (target.size && generated.length > 0) ? generated.length / target.size : null
      let sameCrs = get(target.crs, "authid") === outCrsId
      for (let i = 0; i < generated.length; i++) {
        let p = generated[i]
        if (!sameCrs) {
          p = reprojectPoint(p, target.crs, outCrs)
        }
        points.push({
          x: p.x, y: p.y,
          name: target.name + " Sample " + (i + 1),
          polygonId: target.id,
          rate: rate
        })
      }
    }

    let requested = pointCount * targets.length
    if (points.length === 0) {
      log("Failed: generated 0 points")
      mainWindow.displayToast(qsTr("No points could be generated on the selected features."))
      return
    }

    if (!addOutputLayer(points, { crs: outCrs })) {
      log("Failed: output layer creation did not complete")
      return
    }

    let message = qsTr("Created %1 random points").arg(points.length)
    if (points.length < requested) {
      message += qsTr(" (requested %1)").arg(requested)
      log("Partial result: requested " + requested + ", generated " + points.length)
    }
    mainWindow.displayToast(message)
    log("Completed: " + points.length + " points added")
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
  function samplePolygon(target, pointCount) {
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
      if (target.kind === "extent") {
        points.push({ x: x, y: y })
        continue
      }
      let candidate = geometryUtils.createGeometryFromWkt("POINT(" + x + " " + y + ")")
      if (geometryUtils.geometryWithin(candidate, target.geometry)) {
        points.push({ x: x, y: y })
      }
    }
    return points
  }

  // Random points at uniformly random distances along a (multi)line,
  // returned in order along the line
  function sampleLine(target, pointCount) {
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
    let distances = []
    for (let i = 0; i < pointCount; i++) {
      distances.push(Math.random() * total)
    }
    distances.sort(function(m, n) { return m - n })
    let points = []
    let s = 0
    for (let i = 0; i < distances.length; i++) {
      while (s < segments.length - 1 && distances[i] > segments[s].start + segments[s].length) {
        s++
      }
      let seg = segments[s]
      let f = Math.min(1, (distances[i] - seg.start) / seg.length)
      points.push({ x: seg.a[0] + f * (seg.b[0] - seg.a[0]),
                    y: seg.a[1] + f * (seg.b[1] - seg.a[1]) })
    }
    return points
  }

  function sampleTarget(target, pointCount) {
    return target.kind === "line" ? sampleLine(target, pointCount)
                                  : samplePolygon(target, pointCount)
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

  // Builds a sampling target from a layer/feature/geometry, or null if unsupported
  function makeTarget(layer, feature, geometry) {
    if (!layer || !feature || !geometry || get(geometry, "isEmpty")) {
      return null
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

  // Selected rows of the feature list model, or if none are selected, the first usable row
  function targetsFromModel(model) {
    let count = model.count
    let selected = []
    let fallback = null
    for (let i = 0; i < count; i++) {
      let index = model.index(i, 0)
      let target = makeTarget(model.data(index, 262), model.data(index, 260),
                              model.data(index, 263))
      if (!target) {
        continue
      }
      if (model.data(index, 258)) {
        selected.push(target)
      } else if (!fallback) {
        fallback = target
      }
    }
    if (selected.length > 0) {
      return selected
    }
    return fallback ? [fallback] : []
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

    let fromModel = attempt("model source", function() {
      if (!model) {
        return []
      }
      log("model.count=" + model.count + "; model.selectedCount=" + model.selectedCount)
      return targetsFromModel(model)
    }) || []
    // Several features are only visible through the model; a single one may also be focused
    if (fromModel.length > 1) {
      return fromModel
    }

    let focused = attempt("focused source", function() {
      if (!selection || !selection.focusedLayer || !selection.focusedFeature) {
        return null
      }
      log("Source (focused): layer=" + selection.focusedLayer.name)
      return makeTarget(selection.focusedLayer, selection.focusedFeature,
                        selection.focusedGeometry)
    })
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
    try {
      let found = findSelectedTargets()
      if (found.length > 0) {
        log("Using " + found.length + " selected feature(s)")
        return found
      }
      log("No selected polygon or line found")
      mainWindow.displayToast(lastError
          ? qsTr("Random Pointcaster: %1 (using map extent)").arg(lastError)
          : qsTr("Random Pointcaster: no polygon or line found, using map extent"))
    } catch (e) {
      log("Could not read selected features: " + e)
      mainWindow.displayToast(qsTr("Random Pointcaster: selection error: %1 (using map extent)").arg(e))
    }
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

  // Adds the points to a layer having Name, InPolygon, Created and Rate fields
  function fillLayer(layer, points, attrs) {
    let nameIndex = layer.fields.indexOf("Name")
    let polyIndex = layer.fields.indexOf("InPolygon")
    let createdIndex = layer.fields.indexOf("Created")
    let rateIndex = layer.fields.indexOf("Rate")
    log("Field indexes: Name=" + nameIndex + ", InPolygon=" + polyIndex
        + ", Created=" + createdIndex + ", Rate=" + rateIndex)
    if (nameIndex < 0 || polyIndex < 0 || createdIndex < 0 || rateIndex < 0) {
      return false
    }
    for (let i = 0; i < points.length; i++) {
      let geometry = geometryUtils.createGeometryFromWkt(
          "POINT(" + points[i].x + " " + points[i].y + ")")
      let feature = featureUtils.createBlankFeature(layer.fields, geometry)
      feature.setAttribute(nameIndex, points[i].name)
      if (points[i].polygonId !== null) {
        feature.setAttribute(polyIndex, points[i].polygonId)
      }
      feature.setAttribute(createdIndex, attrs.created)
      if (points[i].rate !== null) {
        feature.setAttribute(rateIndex, points[i].rate)
      }
      if (!layerUtils.addFeature(layer, feature)) {
        log("addFeature failed for point " + i)
        return false
      }
    }
    return true
  }

  // Memory layer with Name, InPolygon (Integer), Created (DateTime) and Rate (Double)
  function createTypedLayer(points, crs, attrs) {
    try {
      if (!featureUtils) {
        log("Feature helper missing")
        return null
      }
      let uri = "Point?crs=" + get(crs, "authid")
          + "&field=Name:string(50)&field=InPolygon:integer64"
          + "&field=Created:datetime&field=Rate:double"
      let layer = layerUtils.loadVectorLayer(uri, layerName(), "memory")
      if (!layer || !get(layer, "isValid")) {
        log("Memory layer with typed fields is invalid; uri=" + uri)
        return null
      }
      return fillLayer(layer, points, attrs) ? layer : null
    } catch (e) {
      log("Typed layer error: " + e)
      return null
    }
  }

  // Fallback: attribute types are inferred, so Created is stored as ISO text
  function createGeoJsonLayer(points, crs, attrs) {
    let features = points.map(function(p, i) {
      let properties = { Name: p.name, Created: attrs.created.toISOString() }
      if (p.polygonId !== null) {
        properties.InPolygon = p.polygonId
      }
      if (p.rate !== null) {
        properties.Rate = p.rate
      }
      return {
        type: "Feature",
        properties: properties,
        geometry: { type: "Point", coordinates: [p.x, p.y] }
      }
    })
    let geojson = JSON.stringify({ type: "FeatureCollection", features: features })
    return layerUtils.memoryLayerFromJsonString(layerName(), geojson, crs)
  }

  // Saves the in-memory layer to a GeoPackage in the project folder and reloads it
  // from disk. Memory layers vanish when QField closes; the file layer survives.
  // Returns the original memory layer if anything fails.
  function persistLayer(memoryLayer, path) {
    let saved = attempt("save to GeoPackage", function() {
      if (typeof layerUtils.saveVectorLayerAs !== "function") {
        log("saveVectorLayerAs not available in this QField build")
        return null
      }
      let result = layerUtils.saveVectorLayerAs(memoryLayer, path, "GPKG")
      log("saveVectorLayerAs -> '" + result + "'")
      if (!result) {
        return null
      }
      let fileLayer = layerUtils.loadVectorLayer(result, layerName(), "ogr")
      return (fileLayer && get(fileLayer, "isValid")) ? { layer: fileLayer, path: result } : null
    })

    if (!saved) {
      mainWindow.displayToast(qsTr("Sample Points: could not save to a file; the layer is temporary"))
      return memoryLayer
    }
    mainWindow.displayToast(qsTr("Sample Points saved to %1").arg(saved.path))
    return saved.layer
  }

  // Appends to the shared GeoPackage if it already exists; returns the layer or null
  function appendToExisting(path, points, attrs) {
    return attempt("append to existing GeoPackage", function() {
      let existing = layerUtils.loadVectorLayer(path, layerName(), "ogr")
      if (!existing || !get(existing, "isValid")) {
        return null
      }
      let before = get(existing, "featureCount")
      if (!fillLayer(existing, points, attrs)) {
        return null
      }
      log("Appended to " + path + "; featureCount " + before + " -> "
          + get(existing, "featureCount"))
      return existing
    })
  }

  function layerAlreadyInProject(path) {
    return attempt("find layer in project", function() {
      let found = qgisProject.mapLayersByName(layerName())
      for (let i = 0; found && i < found.length; i++) {
        let source = String(get(found[i], "source")).split("|")[0]
        if (source.replace(/\\/g, "/") === path) {
          return true
        }
      }
      return false
    })
  }

  // Finds a point layer named "Sample Points" that is already part of the project
  function findProjectSampleLayer() {
    return attempt("find project Sample Points layer", function() {
      let found = qgisProject.mapLayersByName(layerName())
      for (let i = 0; found && i < found.length; i++) {
        let layer = found[i]
        if (get(layer, "isValid") && get(layer, "geometryType") === 0) {
          return layer
        }
      }
      return null
    })
  }

  // Adds the points straight into the project's own layer so that QFieldCloud /
  // QFieldSync see them as ordinary edits
  function appendToProjectLayer(layer, points, target, attrs) {
    return attempt("append to project layer", function() {
      let layerCrsId = get(layerCrs(layer), "authid")
      let sourceCrsId = get(target.crs, "authid")
      let pts = points
      if (layerCrsId && sourceCrsId && layerCrsId !== sourceCrsId) {
        log("Reprojecting points " + sourceCrsId + " -> " + layerCrsId)
        pts = points.map(function(p) {
          let q = reprojectPoint(p, target.crs, layerCrs(layer))
          return { x: q.x, y: q.y, name: p.name, polygonId: p.polygonId, rate: p.rate }
        })
      }
      let before = get(layer, "featureCount")
      if (!fillLayer(layer, pts, attrs)) {
        return false
      }
      log("Appended to project layer; featureCount " + before + " -> " + get(layer, "featureCount"))
      return true
    })
  }

  function addOutputLayer(points, target) {
    log("Creating output layer")
    let attrs = { created: new Date() }
    log("Points=" + points.length)

    let projectLayer = findProjectSampleLayer()
    if (projectLayer) {
      if (appendToProjectLayer(projectLayer, points, target, attrs)) {
        attempt("repaint", function() { projectLayer.triggerRepaint() })
        mainWindow.displayToast(qsTr("Added %1 points to the project's Sample Points layer").arg(points.length))
        return true
      }
      log("Project layer exists but could not be written; using sample_points.gpkg instead")
    }

    let folder = attempt("project folder", function() { return qgisProject.homePath })
    let path = folder ? String(folder).replace(/\\/g, "/") + "/sample_points.gpkg" : ""

    let layer = path ? appendToExisting(path, points, attrs) : null
    if (layer) {
      if (layerAlreadyInProject(path)) {
        attempt("repaint", function() { layer.triggerRepaint() })
        mainWindow.displayToast(qsTr("Added %1 points to sample_points.gpkg").arg(points.length))
        attempt("refresh", function() { mapCanvas.refresh() })
        return true
      }
      mainWindow.displayToast(qsTr("Added %1 points to sample_points.gpkg").arg(points.length))
    } else {
      layer = createTypedLayer(points, target.crs, attrs)
      if (!layer) {
        log("Typed layer failed; falling back to GeoJSON layer without typed fields")
        layer = createGeoJsonLayer(points, target.crs, attrs)
      }
      if (!layer || !get(layer, "isValid")) {
        log("Failed: output layer is null or invalid")
        mainWindow.displayToast(qsTr("Could not create the sample-points layer."))
        return false
      }
      if (path) {
        layer = persistLayer(layer, path)
      }
    }

    if (!projectUtils.addMapLayer(qgisProject, layer)) {
      log("Failed: addMapLayer returned false")
      mainWindow.displayToast(qsTr("Could not add the layer to the project."))
      return false
    }
    log("Output layer added to project")
    return true
  }
}
