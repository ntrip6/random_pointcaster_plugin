# Random Pointcaster Plugin for QField

This is a QField app-wide plugin written in QML/JavaScript.

## Install
In QField **Settings > Plugins > Install plugin from URL** (using a URL to the ZIP)
https://github.com/ntrip6/random_pointcaster_plugin/raw/refs/heads/main/random_pointcaster_plugin-0.3.0.zip

Look for a tool in the top right corner of screen. 

In order for the Sample Points to be synced back to QGIS begin by adding [the template](template/random_pointcaster_template.gpkg) file to the GIS project prior to packaging for QField or QFieldCloud. The template field attributes expected by the plugin tool are listed below.

## Use

Install in QField, zoom to study area, and tap the Random Pointcaster plugin toolbar button. The dialog lists the selected features with their size (m² for polygons, m for lines) and asks how many points to create **in each** feature.
To generate points inside polygons or along lines begin by selecting one or more polygons or lines (open the feature form, or multi-select features in the identify list), then click the toolbar button.

- Polygons: points are sampled randomly inside each polygon. Overlapping polygons are sampled independently, so overlapping areas receive more points; the plugin shows a notice when it detects this.
- Lines: points are placed at random distances along each line.
- Nothing selected: points are sampled inside the visible map extent. No sampling rate is reported. Density mode is not available for the map extent.
- **Number or density:** choose a fixed number of points per feature, or a density (points per 1,000 m² for polygons, per 100 m for lines). With density, each feature gets `round(size × density)` points, at least 1.
- **Minimum distance (m):** optional. No two points from one run (across all selected features) will be closer than this. If it can't be met after 200 tries per point, fewer points are created and the notice says so. Points from earlier runs are not considered.

How to select multiple lines or polygons in QField: multi-selection mode is available by long-pressing on a layer name or an attribute form. 
Polygons and lines should be in a projected CRS with meter units (not degrees).

## Output attributes

| Field       | Type          | Content                                                        |
|-------------|---------------|----------------------------------------------------------------|
| `Name`      | Text (50)     | `<feature name> Sample <n> <HH:mm:ss>`, e.g. `Lake Sample 2 14:32:05` |
| `InFeature` | Integer       | FID of the polygon or line the point belongs to (empty for map extent) |
| `Created`   | Date/time     | Full creation date and time of each point                      |
| `RunSamplingPct` | Decimal   | Percent of the feature sampled, assuming 1 m² (polygons) or 1 m (lines) per point: points ÷ area or length × 100 |

The feature name is read from the first non-empty field called `Name`, `Label`
or `Title` (case-insensitive, in that order). If none exists, `Polygon <FID>`
or `Line <FID>` is used. Without a selection, the name is `Map extent`.

## Where the points go, and syncing back to QGIS Desktop

QField does not save layers created at runtime into the project, so the
plugin writes into a layer that already exists in your project when it can.

1. **Project layer (recommended, syncs).** If the project contains a point
   layer named exactly `Sample Points`, the plugin adds the points directly to
   it. Because it is a normal project layer, QFieldCloud and QFieldSync treat
   the new points as ordinary edits and bring them back to Desktop.
2. **Fallback (does not sync).** If there is no such layer, or it cannot be
   written to, the plugin saves the points to `random_pointcaster.gpkg` in
   QField's own folder on the device (the project folder is used only if that
   fails) and appends to it on later runs. The toast after each run shows the
   full path. The layer is added to the project as `Sample Points <HH:mm:ss>`
   (time of the run), but QField does not keep it in the project, so it
   disappears when the project is closed. The `.gpkg` file stays on the device.

### Getting the fallback points back to desktop GIS

The points from every run accumulate in `random_pointcaster.gpkg`, which is not
synced. Use the **Export** button (the box-with-arrow icon next to the plugin
button in the toolbar) at any time, including after QField has been restarted:

- **Share** opens the system share sheet (email, Drive, AirDrop, etc.).
- **Save a copy** lets you choose a folder or USB stick.

Either way you get one file containing all runs. In QGIS, add it with
**Layer > Add Layer > Add Vector Layer**.

#### Where the file is stored

`random_pointcaster.gpkg` is saved in QField's app directory. The toast after a
run shows the exact path, and QField's **About QField** screen lists the app
directory too.

| Platform | Location |
|----------|----------|
| Android  | `Internal Storage/Android/data/ch.opengis.qfield/files/QField/random_pointcaster.gpkg` (visible over USB in File transfer mode) |
| iOS      | Files app > On My iPhone/iPad > QField > `random_pointcaster.gpkg` |

### Set up in QGIS Desktop before packaging or syncing

**Easiest:** copy [`template/random_pointcaster_template.gpkg`](template/random_pointcaster_template.gpkg)
into your project folder and add its `Sample Points` layer to the project. It is
EPSG:4326 (so no UTM zone to worry about), already has the fields below, and
carries a default style that labels each point with just its sample number in
a small font, visible only at scales of 1:10,000 or larger. Then skip to step 4.
(Sampling and sizes are still computed in the CRS of your polygons/lines; points
are reprojected to 4326 on write.)

**Or build it by hand:**

1. Create a GeoPackage in the project folder, e.g. `sample_points.gpkg`
   (**Layer > Create Layer > New GeoPackage Layer**).
2. Table/layer name `Sample Points`, geometry type **Point**, CRS EPSG:4326
   (other CRSs are reprojected).
3. Add exactly these fields (names are case-sensitive):
   - `Name`: Text (string), length 50, for labeling
   - `InFeature`: Integer (64 bit), for joining with feature
   - `Created`: Date & Time, now
   - `RunSamplingPct`: Decimal (double). Percent of the feature sampled, assuming 1 m² per point for polygons or 1 m per point for lines
4. Add the layer to the project, name it `Sample Points`, and make sure it is
   editable (do not set it read-only).
5. Package for QField with QFieldSync or push to QFieldCloud as usual. Set the
   layer to be available for editing/offline editing as you do for other
   data layers.
6. After fieldwork, synchronise as usual; the sample points appear in the
   `Sample Points` layer on Desktop.

Troubleshooting: the Message Log lines starting with `[Random Pointcaster]` show
which route was used (`Appended to project layer; featureCount X -> Y`).
