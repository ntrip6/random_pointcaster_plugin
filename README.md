# Random Pointcaster Plugin for QField

This is a QField app-wide plugin written in QML/JavaScript. QField does not
load the Python plugin API used by QGIS Desktop.

## Install

Zip the contents of this folder so that `main.qml`, `metadata.txt`, and
`icon.svg` are at the root of the archive. Install that ZIP in QField under
**Settings > Plugins > Install plugin from URL** (using a URL to the ZIP).

## Use

Select a polygon (open its feature form), tap the plugin toolbar button, and
choose a point count. Points are sampled inside the selected polygon. With no
polygon selected, they are sampled inside the visible map extent.

Polygons must be in a projected CRS with metre units (not degrees).

## Output attributes

| Field       | Type          | Content                                                        |
|-------------|---------------|----------------------------------------------------------------|
| `Name`      | Text (50)     | `<polygon name> Sample <n>`, e.g. `Lake Sample 2`             |
| `InPolygon` | Integer       | FID of the polygon containing the point (empty for map extent) |
| `Created`   | Date/time     | Full creation date and time of each point                      |
| `Rate`      | Decimal       | Points in this run divided by polygon area in m2 (1 m2 per sample) |

The polygon name is read from the first non-empty field called `Name`, `Label`
or `Title` (case-insensitive, in that order). If none exists, `Polygon <FID>`
is used. Without a polygon, the name is `Map extent`.

## Where the points go, and syncing back to QGIS Desktop

QField does not save layers created at runtime into the project, so the
plugin writes into a layer that already exists in your project when it can.

1. **Project layer (recommended, syncs).** If the project contains a point
   layer named exactly `Sample Points`, the plugin adds the points directly to
   it. Because it is a normal project layer, QFieldCloud and QFieldSync treat
   the new points as ordinary edits and bring them back to Desktop.
2. **Fallback (does not sync).** If there is no such layer, or it cannot be
   written to, the plugin creates `sample_points.gpkg` in the project folder
   (appending on later runs) and adds it as `Sample Points`. This file is not
   part of the project, so it is not synced automatically. Copy it off the
   device and add it in QGIS Desktop.

### Set up in QGIS Desktop before packaging or syncing

1. Create a GeoPackage in the project folder, e.g. `sample_points.gpkg`
   (**Layer > Create Layer > New GeoPackage Layer**).
2. Table/layer name `Sample Points`, geometry type **Point**, and the same CRS
   as your polygons (other CRSs are reprojected, but matching is safest).
3. Add exactly these fields (names are case-sensitive):
   - `Name`: Text (string), length 50
   - `InPolygon`: Integer (64 bit)
   - `Created`: Date & Time
   - `Rate`: Decimal (double)
4. Add the layer to the project, name it `Sample Points`, and make sure it is
   editable (do not set it read-only).
5. Package for QField with QFieldSync or push to QFieldCloud as usual. Set the
   layer to be available for editing/offline editing as you do for other
   data layers.
6. After fieldwork, synchronise as usual; the sample points appear in the
   `Sample Points` layer on Desktop.

Troubleshooting: the Message Log lines starting with `[Random Pointcaster]` show
which route was used (`Appended to project layer; featureCount X -> Y`).
