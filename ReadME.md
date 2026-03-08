# Custom Dwarf Maker
By IansInventories

A standalone dwarf portrait generator inspired by Dwarf Fortress.

## Includes
- Random dwarf generation
- Manual part cycling
- RP writer
- DF Mind panel
- JSON export/import
- DFHack exporter support

## Files
- `index.html` — main generator
- `assets/` — art assets
- `dwarfexportfinal.lua` — DFHack export script
- `examples/` — sample dwarf JSON files

## How to use
1. Download or clone this repo
2. Keep `index.html` in the same folder as `assets`
3. Open `index.html` in your browser
4. Click **Randomize**

## DFHack Export
Place `dwarfexportfinal.lua` into your DFHack scripts folder:

`Dwarf Fortress/data/dfhack/scripts/`

Then run in DFHack:

`dwarfexportfinal`

or:

`dwarfexportfinal UNIT_ID`

## JSON Types

The generator supports two types of JSON files.

### DF Export JSON
Created using the DFHack script:

dwarfexportfinal

These files contain raw dwarf data exported from Dwarf Fortress.

The generator interprets these files to build a portrait.

### Generator JSON
Saved from inside the Custom Dwarf Maker.

These are hybrid files containing:

• portrait selections
• RP writer content
• generator adjustments

Loading these restores the dwarf exactly as it was saved.

## Notes
This is a beta / v1 release. Some art and parsing may still be refined.

THERE ARE BUGS! 



## Credits
Created by IansInventories
Inspired by Dwarf Fortress