<!-- cspell:words DPDT AXICOM Littelfuse Lumberg Wuerth dshapes -->
# Screen-power assembly models

Every populated component in the board has a project-relative STEP model.
The models are stored beside the native hand folder so KiCad does not need
machine-specific 3D library paths. Bare M3 mounting holes intentionally have
no solid body. Screws, mating plugs, cable bends and enclosure clearance are
not included in the populated board model.

## Custom models

These three models were drawn for Segno with `model_geometry.py` and CadQuery
2.8. They are original simplified assembly geometry under the repository's
GPL-3.0 license, not manufacturer-supplied CAD. Dimensions are nominal except
where explicitly described as maximum; molded details and lead bends are
simplified. Use the linked manufacturer drawings for mechanical qualification.

| File stem | Published geometry used | Source |
| --- | --- | --- |
| Relay_DPDT_AXICOM_IMSeries_Pitch5.08mm | 10 × 6 × 5.65 mm; 0.25 mm standoff; eight 0.4 × 0.2 mm leads, 5.08 mm row spacing, 3.2 mm lead projection | [TE IM02TS, customer drawing 1462037-4](https://www.te.com/en/product-1-1462037-3.html) |
| Fuse_Littelfuse_251_P12.70mm | Maximum 7.11 × diameter 2.8 mm body; 0.64 mm leads formed at 12.7 mm pitch; 0.4 mm assembly standoff | [Littelfuse 251](https://www.littelfuse.com/assetdocs/fuse-251-datasheet?assetguid=f47a0bb7-8ede-4679-9646-7114c3787688) |
| JST_VH_B2P-VH_1x02_P3.96mm_Vertical | 7.86 × 8.5 × 10.9 mm header envelope, 3.96 mm pitch | [JST VH standard header](https://www.jst-mfg.com/product/pdf/eng/eVH.pdf) |

Insulation, relay markings and connector latches are represented
only sufficiently to identify orientation and occupied space. Models do not
establish mating fit, contact geometry, latch accessibility, or worst-case
component tolerances. The PCB footprints, drills and manufacturer drawings
remain authoritative for assembly.

## KiCad models

The other STEP files are unmodified models copied from the installed KiCad 10
library. Original attribution remains in STEP headers; directory credits are
retained in `licenses/`. They are redistributed under CC-BY-SA 4.0 with KiCad's
library exception, as reproduced in [LIBRARY_LICENSE.txt](../LIBRARY_LICENSE.txt).
Sources are the matching libraries in the
[KiCad 3D models collection](https://gitlab.com/kicad/libraries/kicad-packages3D).

| Files | Upstream library |
| --- | --- |
| CP_Radial*, C_Rect* | Capacitor_THT.3dshapes |
| D_DO-* | Diode_THT.3dshapes |
| JST_XH* | Connector_JST.3dshapes |
| R_Axial* | Resistor_THT.3dshapes |
| TO-220*, TO-92* | Package_TO_SOT_THT.3dshapes |

`check.py` rejects missing, disabled, unresolved or wrongly formatted model
assignments. Native STEP export, populated renders and independent solid
parsing provide additional verification; the assignment check alone is not
a STEP geometry validator.
