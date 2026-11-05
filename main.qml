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
  property var pendingTarget: null

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
        plugin.pendingTarget = plugin.targetGeometryAndCrs()
      } catch (e) {
        plugin.pendingTarget = null
        log("ERROR capturing target: " + e)
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

      Label {
        text: qsTr("Number of points to generate:")
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
    let target = pendingTarget
    pendingTarget = null
    if (!target) {
      target = targetGeometryAndCrs()
    }
    if (!target || get(target.geometry, "isEmpty")) {
      log("Failed: target geometry is missing or empty")
      mainWindow.displayToast(qsTr("No valid polygon or map extent is available."))
      return
    }

    let bounds = geometryUtils.boundingBox(target.geometry)
    let xMin = get(bounds, "xMinimum")
    let xMax = get(bounds, "xMaximum")
    let yMin = get(bounds, "yMinimum")
    let yMax = get(bounds, "yMaximum")
    log("Bounds: " + xMin + "," + yMin + " to " + xMax + "," + yMax
        + "; polygon test: " + !target.isExtent)
    let points = []
    let attempts = 0
    let maxAttempts = pointCount * 200

    while (points.length < pointCount && attempts < maxAttempts) {
      attempts += 1
      let x = xMin + Math.random() * (xMax - xMin)
      let y = yMin + Math.random() * (yMax - yMin)
      if (target.isExtent) {
        points.push({ x: x, y: y })
        continue
      }
      let candidate = geometryUtils.createGeometryFromWkt("POINT(" + x + " " + y + ")")
      if (geometryUtils.geometryWithin(candidate, target.geometry)) {
        points.push({ x: x, y: y })
      }
    }

    if (points.length === 0) {
      log("Failed: generated 0 points after " + attempts + " attempts")
      mainWindow.displayToast(qsTr("No points could be generated inside the selected area."))
      return
    }

    log("Generated " + points.length + " points after " + attempts + " attempts")
    if (!addOutputLayer(points, target)) {
      log("Failed: output layer creation did not complete")
      return
    }

    let message = qsTr("Created %1 random points").arg(points.length)
    if (points.length < pointCount) {
      message += qsTr(" (requested %1)").arg(pointCount)
      log("Partial result: requested " + pointCount + ", generated " + points.length)
    }
    mainWindow.displayToast(message)
    log("Completed: " + points.length + " points added")
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

  // A layer whose geometry type can't be read is not rejected here
  function isPolygonLayer(layer) {
    let type = attempt("geometryType", function() { return get(layer, "geometryType") })
    return type === null || type === undefined || type == 2
  }

  function polygonFromModel(model) {
    let count = model.count
    let fallback = null
    for (let i = 0; i < count; i++) {
      let index = model.index(i, 0)
      let layer = model.data(index, 262)
      let geometry = model.data(index, 263)
      let feature = model.data(index, 260)
      if (!layer || !geometry || !feature || !isPolygonLayer(layer)
          || get(geometry, "isEmpty")) {
        continue
      }
      let candidate = { layer: layer, geometry: geometry, feature: feature }
      if (model.data(index, 258)) {
        return candidate
      }
      if (!fallback) {
        fallback = candidate
      }
    }
    return fallback
  }

  function findSelectedPolygon() {
    let featureForm = iface.findItemByObjectName("featureForm")
    log("featureForm=" + (featureForm ? "found" : "null"))
    if (!featureForm) {
      return null
    }

    let selection = attempt("read selection", function() { return featureForm.selection })
    let model = attempt("read model", function() { return featureForm.model })
    log("selection=" + (selection ? "found" : "null")
        + "; model=" + (model ? "found" : "null"))

    let focused = attempt("focused source", function() {
      if (!selection || !selection.focusedLayer || !selection.focusedFeature) {
        return null
      }
      let layer = selection.focusedLayer
      let geometry = selection.focusedGeometry
      log("Source 1 (focused): layer=" + layer.name)
      if (geometry && isPolygonLayer(layer) && !get(geometry, "isEmpty")) {
        return { layer: layer, geometry: geometry, feature: selection.focusedFeature }
      }
      return null
    })
    if (focused) {
      return focused
    }

    let found = attempt("model source", function() {
      if (!model) {
        return null
      }
      log("model.count=" + model.count + "; model.selectedCount=" + model.selectedCount)
      return polygonFromModel(model)
    })
    log("Source 2 (model rows): " + (found ? "found polygon in " + found.layer.name : "none"))
    return found
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

  function targetGeometryAndCrs() {
    lastError = ""
    try {
      let found = findSelectedPolygon()
      if (found) {
        let polygonId = found.feature.id
        let crs = layerCrs(found.layer)
        log("Using polygon " + polygonId + " from layer " + found.layer.name
            + "; CRS=" + get(crs, "authid"))
        mainWindow.displayToast(qsTr("Random Pointcaster: using polygon %1 from %2")
            .arg(polygonId).arg(found.layer.name))
        return {
          geometry: found.geometry,
          crs: crs,
          isExtent: false,
          polygonId: polygonId,
          polygonName: polygonNameOf(found.feature, found.layer)
        }
      }
      log("No selected polygon found")
      mainWindow.displayToast(lastError
          ? qsTr("Random Pointcaster: %1 (using map extent)").arg(lastError)
          : qsTr("Random Pointcaster: no polygon found, using map extent"))
    } catch (e) {
      log("Could not read selected feature: " + e)
      mainWindow.displayToast(qsTr("Random Pointcaster: selection error: %1 (using map extent)").arg(e))
    }
    let settings = mapCanvas.mapSettings
    let extent = settings.visibleExtent
    let x1 = get(extent, "xMinimum")
    let x2 = get(extent, "xMaximum")
    let y1 = get(extent, "yMinimum")
    let y2 = get(extent, "yMaximum")
    log("Using visible map extent")
    return {
      geometry: geometryUtils.createGeometryFromWkt(
        "POLYGON((" + x1 + " " + y1 + "," + x2 + " " + y1 + "," + x2 + " " + y2
        + "," + x1 + " " + y2 + "," + x1 + " " + y1 + "))"),
      crs: settings.destinationCrs,
      isExtent: true
    }
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
      feature.setAttribute(nameIndex, attrs.name + " Sample " + (i + 1))
      if (attrs.polygonId !== null) {
        feature.setAttribute(polyIndex, attrs.polygonId)
      }
      feature.setAttribute(createdIndex, attrs.created)
      if (attrs.rate !== null) {
        feature.setAttribute(rateIndex, attrs.rate)
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
      let properties = { Name: attrs.name + " Sample " + (i + 1), Created: attrs.created.toISOString() }
      if (attrs.polygonId !== null) {
        properties.InPolygon = attrs.polygonId
      }
      if (attrs.rate !== null) {
        properties.Rate = attrs.rate
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
          let g = geometryUtils.createGeometryFromWkt("POINT(" + p.x + " " + p.y + ")")
          let r = geometryUtils.reprojectGeometry(g, target.crs, layerCrs(layer))
          let wkt = String(get(r, "asWkt")).match(/\(\s*(\S+)\s+(\S+)\s*\)/)
          if (!wkt) {
            throw new Error("reprojection failed")
          }
          return { x: parseFloat(wkt[1]), y: parseFloat(wkt[2]) }
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
    let polygonId = target.polygonId
    let hasPolygon = polygonId !== undefined && polygonId !== null
    let area = areaSquareMeters(target.geometry)
    let rate = area ? points.length / area : null
    let attrs = {
      name: hasPolygon ? (target.polygonName ? target.polygonName : "Polygon " + polygonId)
                       : "Map extent",
      polygonId: hasPolygon ? polygonId : null,
      created: new Date(),
      rate: rate
    }
    log("Points=" + points.length + "; area=" + area + " m2; rate=" + rate)

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
