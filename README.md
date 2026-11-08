# Random Pointcaster Plugin for QField

This is a QField app-wide plugin written in QML/JavaScript. Version 0.4.2
stores points from multiple sampling runs in one `Sample Points` layer, with
run metadata on each point.

## Install
In QField **Settings > Plugins > Install plugin from URL** (using a URL to the ZIP)
https://github.com/ntrip6/random_pointcaster_plugin/raw/refs/heads/main/random_pointcaster_plugin-0.4.2.zip

Look for the Random Pointcaster button.

In order for the Sample Points to be synced back to QGIS begin by adding [the template](template/random_pointcaster_template.gpkg) file to the GIS project prior to packaging for QField or QFieldCloud. The template field attributes expected by the plugin tool are listed below.

## Use

Install in QField, zoom to study area, and tap the Random Pointcaster plugin toolbar button. The dialog lists the selected features with their size (m² for polygons, m for lines) and asks how many points to create **in each** feature.
To generate points inside polygons or along lines begin by selecting one or more polygons or lines (open the feature form, or multi-select features in the identify list), then click the toolbar button.

- Polygons: points are sampled randomly inside each polygon. Overlapping polygons are sampled independently.
- Lines: points are placed at random distances along each line.
- Curved geometries are not supported. 
- Nothing selected: points are sampled inside the visible map extent. No sampling rate is reported; density mode is not available.
- **Number or density:** choose a fixed number of points per feature, or a density (points per 1,000 m² for polygons, per 100 m for lines). For a positive density and known feature size, the requested count is `max(1, round(size / unit × density))`, where `unit` is 1,000 m² or 100 m.
- **Minimum distance (m):** optional. Points generated in the same run are checked against earlier points from that run in the same CRS, including points from other selected features. 

For map-extent sampling in a geographic CRS, minimum distance is disabled and
recorded as 0.

How to select multiple lines or polygons in QField: multi-selection mode is available by long-pressing on a layer name or an attribute form. 
Polygons and lines should be in a projected CRS with metre units (not degrees).
Use the same CRS for all selected features if the minimum distance must apply
between them.

## Output attributes

| Field | Type | Content |
|-------|------|---------|
| `RunID` | Text (36) | UTC start timestamp and random suffix, shared by all points in a run (e.g. `20261108T143200Z-ab12`) |
| `RunCreated` | Date/time | Time when the run started |
| `RunName` | Text (50) | `<feature name> - <YYYY-MM-DD HH:mm>` in UTC, or `Multiple features - <YYYY-MM-DD HH:mm>` |
| `Name` | Text (100) | `<feature name> Sample <n> <HH:mm:ss>` |
| `InFeature` | Integer (64 bit) | Source feature ID (empty for map extent) |
| `Created` | Date/time | Creation time of the point |
| `RunSamplingPct` | Decimal | Percent of the source feature sampled, assuming 1 m² (polygons) or 1 m (lines) per point: generated points ÷ area or length × 100; empty for map extent or unknown size |
| `Requested` | Integer (64 bit) | Total points requested across all features in the run |
| `Generated` | Integer (64 bit) | Total points generated across all features in the run |
| `MinDistance` | Decimal | Minimum-distance setting in metres |
| `Mode` | Text (10) | `count` or `density` |

All run-level values are shared by every point from the same operation. Use
`RunID` to group points from a run; `RunName` is a readable label rather than a
unique identifier. The point `Name` retains its time suffix, but the **layer**
name is always `Sample Points` without a timestamp.
`RunSamplingPct` describes each point's source feature and may differ between
features in the same run.
Long feature names are shortened as needed to fit the `Name` and `RunName`
fields while preserving the sample number and time suffixes.
Existing `RunNumber` fields are ignored and may be retained when upgrading.

The feature name is read from the first non-empty field called `Name`, `Label`
or `Title` (case-insensitive, in that order). If none exists, `Polygon <FID>`
or `Line <FID>` is used. Without a selection, the name is `Map extent`.

## Where the points go, and syncing back to QGIS Desktop

QField persists edits to existing project layers. A plugin-created layer is not automatically added to the saved .qgs/.qgz project definition. Random Pointcaster therefore writes to an existing Sample Points layer when available; otherwise it saves a persistent random_pointcaster.gpkg beside the project and reloads it when the plugin reopens the project.

1. **Project layer (recommended, syncs).** If the project contains a point
   layer named exactly `Sample Points`, the plugin adds the points directly to
   it. 
2. **Project-folder file (does not automatically sync).** If there is no such
   layer, the plugin creates `random_pointcaster.gpkg` alongside the current
   project file and appends to it on later runs. It adds the file as
   `Sample Points` for the current session and reloads it when the project is
   reopened while the plugin is enabled. An open, saved project and a writable
   project folder are required; the plugin does not fall back to the app
   directory.

The project-folder file uses the CRS of the first sampled target when it is
created. Later points are reprojected to the existing layer's CRS when needed.

If an existing `Sample Points` layer is missing required fields or cannot be
written, the plugin reports an error instead of silently creating another
dataset. If both a different project layer named `Sample Points` and a
`random_pointcaster.gpkg` file are present, resolve the conflict before
generating more points; neither dataset is overwritten. If writing fails
partway through a run, some points may already have been added; inspect the
layer before retrying.

### Exporting project-folder points

QField's **Compress project and send to...** action archives the project folder,
including `random_pointcaster.gpkg`. Check the resulting ZIP before removing
the device copy. 

### Set up in QGIS Desktop before packaging or syncing

**Easiest:** copy [`template/random_pointcaster_template.gpkg`](template/random_pointcaster_template.gpkg)
into your project folder and add its `Sample Points` layer to the project. It is
EPSG:4326 (so no UTM zone to worry about), already has the fields below, and
carries a default style that labels each point with its sample number.

**Or build it by hand:**

1. Create a GeoPackage in the project folder, e.g. `sample_points.gpkg`
   (**Layer > Create Layer > New GeoPackage Layer**).
2. Table/layer name `Sample Points`, geometry type **Point**, CRS EPSG:4326
   (other CRSs are reprojected).
3. Add the fields in the **Output attributes** table above (names are
   case-sensitive). Leave them nullable.
4. Add the layer to the project, name it `Sample Points`, and make sure it is
   editable (do not set it read-only).
5. Package for QField with QFieldSync or push to QFieldCloud as usual. Set the
   layer to be available for editing/offline editing as you do for other
   data layers.
6. After fieldwork, synchronise as usual; the sample points appear in the
   `Sample Points` layer on Desktop.

Troubleshooting: the Message Log lines starting with `[Random Pointcaster]` show
which route was used (`Appended to project layer; featureCount X -> Y`).
If adding a point fails, the plugin's error dialog also displays available
QField write-error details; select the text to copy it for troubleshooting.
