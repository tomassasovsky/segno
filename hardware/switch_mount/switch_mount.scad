/* ================================================================
 * MX Switch Footswitch Mount — First Design Iteration
 * Designed for Akko V3 Fairy Linear Silent (MX-compatible)
 *
 * NOTE: This is the first design (bracket with mounting ears).
 * The final design used is switch_box.stl — regenerate it with
 * generate_stl.py.  This file is kept for reference / further
 * experimentation in OpenSCAD.
 *
 * PRINT SETTINGS
 *   Material  : PETG or ABS (PLA fine for light use)
 *   Layer     : 0.2 mm
 *   Infill    : 40 %+
 *   Supports  : not required
 *   Orientation: flat bottom face on the bed
 * ================================================================ */

$fn = 48;

SW_W        = 15.6;
SW_L        = 15.6;
SW_H        = 11.9;

PIN_X       = 3.81;
PIN_Y       = 2.54;
INCLUDE_PIN3 = true;
PIN3_Y      = 5.08;
PIN_SHAFT_D = 1.5;

TOL         = 0.25;
WALL        = 2.5;
FLOOR       = 2.0;
SOLDER_D    = 4.0;
CABLE_D     = 7.0;
EAR_W       = 8.0;
EAR_H       = FLOOR;
M3_D        = 3.4;

INNER_W     = SW_W + 2 * TOL;
INNER_L     = SW_L + 2 * TOL;
OUTER_W     = INNER_W + 2 * WALL;
OUTER_L     = INNER_L + 2 * WALL;
OUTER_H     = SW_H + FLOOR;

CX = OUTER_W / 2;
CY = OUTER_L / 2;

module cylinder_z(h, d) { cylinder(h = h, d = d, center = false); }

difference() {
    union() {
        cube([OUTER_W, OUTER_L, OUTER_H]);
        translate([-EAR_W, -EAR_W, 0])
            cube([EAR_W + WALL, EAR_W + WALL, EAR_H]);
        translate([OUTER_W - WALL, -EAR_W, 0])
            cube([EAR_W + WALL, EAR_W + WALL, EAR_H]);
        translate([-EAR_W, OUTER_L - WALL, 0])
            cube([EAR_W + WALL, EAR_W + WALL, EAR_H]);
        translate([OUTER_W - WALL, OUTER_L - WALL, 0])
            cube([EAR_W + WALL, EAR_W + WALL, EAR_H]);
    }
    translate([WALL + TOL, WALL + TOL, FLOOR])
        cube([INNER_W, INNER_L, SW_H + 1]);
    translate([CX - PIN_X, CY + PIN_Y, -0.1])
        cylinder_z(FLOOR + 0.2, SOLDER_D);
    translate([CX + PIN_X, CY + PIN_Y, -0.1])
        cylinder_z(FLOOR + 0.2, SOLDER_D);
    if (INCLUDE_PIN3) {
        translate([CX, CY - PIN3_Y, -0.1])
            cylinder_z(FLOOR + 0.2, SOLDER_D);
    }
    translate([CX, OUTER_L - 0.1, FLOOR + CABLE_D / 2 + 1])
        rotate([90, 0, 0])
            cylinder_z(WALL + 0.2, CABLE_D);
    ear_hole_z = EAR_H + 0.1;
    translate([-EAR_W / 2, -EAR_W / 2, -0.1])
        cylinder_z(ear_hole_z, M3_D);
    translate([OUTER_W + EAR_W / 2, -EAR_W / 2, -0.1])
        cylinder_z(ear_hole_z, M3_D);
    translate([-EAR_W / 2, OUTER_L + EAR_W / 2, -0.1])
        cylinder_z(ear_hole_z, M3_D);
    translate([OUTER_W + EAR_W / 2, OUTER_L + EAR_W / 2, -0.1])
        cylinder_z(ear_hole_z, M3_D);
}
