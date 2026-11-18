/*
 * segno_fx_kinds.h — the VST3 classes Segno.vst3 exposes: one per built-in
 * effect kind (le_fx_type), every kind but LE_FX_NONE and LE_FX_PLUGIN.
 *
 * The class ids are the plugins' identity. A Live set names a plugin by its
 * processor class id alone, so they never change once shipped, also when a
 * kind's sound does. packages/daw_export writes the same ids into the sets
 * it exports (segno_vst3_plugins.dart), and its tests read this file to
 * check the two tables agree.
 *
 * Names are the console's (TrackEffectType's labels), with "Segno " before
 * them, so Live lists them together.
 */
#pragma once

#include <cstdint>

namespace segno_vst3 {

struct FxKind {
  int32_t type;            /* le_fx_type */
  const char* name;        /* the plugin's name in a host */
  const char* subcategory; /* the VST3 subcategory string */
  uint32_t processor[4];   /* processor class id, four big-endian words */
  uint32_t controller[4];  /* edit controller class id */
};

// clang-format off
constexpr FxKind kFxKinds[] = {
    {1, "Segno Drive", "Fx|Distortion", {0x3B6057BF, 0xB0624797, 0xABA2EBB8, 0x599AAE91}, {0xB526F23C, 0xEAB34A82, 0x9785E64C, 0xD112C417}},
    {2, "Segno Filter", "Fx|Filter", {0x20A68767, 0x71C5463A, 0x92BC2E0C, 0x3A02E613}, {0x78D821F6, 0x4A7440F7, 0x82723DD3, 0x5B411D42}},
    {3, "Segno Delay", "Fx|Delay", {0x6E698A08, 0x1C5445D5, 0xB5C0F9A1, 0xF2543803}, {0xEBB33A3B, 0x8C21406B, 0x80DCA8AE, 0xBE5C0097}},
    {4, "Segno Tremolo", "Fx|Modulation", {0xD8E602FC, 0x6B25466E, 0xAEB1BB29, 0x337E80CD}, {0x1A9CAE81, 0x7D874BCB, 0xB3278EB3, 0x319CAE59}},
    {5, "Segno Octaver", "Fx|Pitch Shift", {0x7486BCEA, 0x59714B95, 0xBFE3C1F1, 0xF344FCFD}, {0x7D2EBCCD, 0x08E142A9, 0x8A8C75DF, 0x8B7B0CBD}},
    {6, "Segno Echo", "Fx|Delay", {0xDC732855, 0x0021497D, 0x8053CD50, 0x94B592D3}, {0xC7F4348B, 0x9E9947A2, 0x9155B7E8, 0x25B512B5}},
    {7, "Segno Reverb", "Fx|Reverb", {0x6E35F5DA, 0x6D4E406F, 0x8D41A81C, 0xBE7AB75F}, {0x973AA357, 0x8F68493E, 0xBE182DCA, 0x2D0A95E7}},
    {9, "Segno EQ", "Fx|EQ", {0x5F221E04, 0x34E74839, 0xB988C082, 0xCF758CD5}, {0xD377813F, 0xA08D499A, 0x8A5B27E1, 0x00E359AB}},
    {10, "Segno Compressor", "Fx|Dynamics", {0x093244E1, 0x13BE424A, 0xB523A1F7, 0x1115929D}, {0xBDF7852C, 0x0DEB4A58, 0x8B161C72, 0xD89D33DD}},
    {11, "Segno Transient", "Fx|Dynamics", {0xBC421B2B, 0x1B414AEB, 0xA078BCE4, 0x440B9006}, {0x289622D8, 0xAF5D4576, 0x94B45196, 0xC087F553}},
    {12, "Segno HP / Gate", "Fx|Dynamics", {0xBE5C001E, 0xAD0F40C4, 0x81A1AAB7, 0x848F11B5}, {0xB0BF390C, 0x101D41AB, 0xA9289BEB, 0x937D4C5A}},
    {13, "Segno Doubler", "Fx|Modulation", {0x18613919, 0xB57F4BE3, 0x8A06BE4B, 0xAB3581C6}, {0xADC35F54, 0xD18D46C9, 0xAA614351, 0xF751C767}},
    {14, "Segno Chorus", "Fx|Modulation", {0x4CDD90BF, 0xAD6E42B9, 0x9BF7EBBD, 0xA91FF8B3}, {0x85281608, 0x811B4DD0, 0x9AA09665, 0x44B61576}},
    {15, "Segno Wah", "Fx|Filter", {0x27D1F229, 0x8C6944DF, 0xAEE761E0, 0x7DF17039}, {0x0CF5382B, 0x1DF7407A, 0x81D24F66, 0x51EB89E6}},
    {16, "Segno Overdrive", "Fx|Distortion", {0x05F5B34F, 0xA3094E55, 0x80299B01, 0x04C0A5CB}, {0x0769B56E, 0x72BE4371, 0xA716E85B, 0xC22CA581}},
    {17, "Segno Distortion", "Fx|Distortion", {0x71C7F461, 0x30A94EDF, 0xA49D96FC, 0x7E81AF28}, {0x15F99FFF, 0xB2164FE1, 0xAF56BE35, 0x26434F3B}},
    {18, "Segno Vinyl", "Fx|Distortion", {0xF03164F2, 0x63044EAA, 0x89609B98, 0x0D51BA07}, {0xA55319BA, 0x320D4468, 0xA8200622, 0x88947B07}},
    {19, "Segno Degrade", "Fx|Distortion", {0x2C5FF786, 0x56F84B19, 0x81A68856, 0x3644BEE5}, {0x8651FCB6, 0x70264399, 0xAEB4F635, 0x1FBD7B08}},
    {20, "Segno LPF", "Fx|Filter", {0x5ED01649, 0x5706426D, 0x8C5FFD74, 0x36121AF9}, {0x9C2EA37A, 0xF12A4554, 0x86342C5E, 0x5745EA3D}},
    {21, "Segno Spring reverb", "Fx|Reverb", {0x18E14C30, 0x251B4735, 0x8FABA270, 0xADB195C7}, {0xBA60B85A, 0xDC494BB4, 0xBED59CF1, 0x0CC44499}},
    {22, "Segno Dub reverb", "Fx|Reverb", {0x7988FD87, 0x94D24BEA, 0xABBA557B, 0xD6F6DF4A}, {0x408EBA93, 0xCE434C4C, 0xA540DC39, 0x3F1A7D6A}},
    {23, "Segno Ambience", "Fx|Reverb", {0x77D9FCDC, 0x6CAC42FE, 0x950885BF, 0xB18D91B6}, {0xCB4096E3, 0xBFEF42C4, 0xB64CCF51, 0xA2785CE4}},
    {24, "Segno Whammy", "Fx|Pitch Shift", {0x6F56732E, 0x46264E80, 0xA861C6DE, 0x71B23ACD}, {0x5143542B, 0xE42747B5, 0xB2C59144, 0xE6AD8E3A}},
    {25, "Segno Pumper", "Fx|Dynamics", {0x2F1E61CC, 0x9892403F, 0x939A97CC, 0x33A9B20D}, {0xD68B002D, 0x6C674427, 0xBCDB83A5, 0x28DFC361}},
    {26, "Segno Slicer", "Fx|Modulation", {0x75C5A76B, 0x73B04920, 0xB23C72F3, 0x07E86AB9}, {0xFABCD241, 0xDA6E4865, 0xB19883B5, 0x4C67D9BD}},
    {27, "Segno Mode delay", "Fx|Delay", {0xC32C951E, 0x2B9846FA, 0xB77984C9, 0x8418854A}, {0x37B1CACA, 0x43FA4CF9, 0xB2EB90EF, 0xFC5DB94A}},
    {28, "Segno Dual octaver", "Fx|Pitch Shift", {0x2D7AF1A0, 0x90624EC0, 0x84535B6C, 0x73DC0897}, {0x9BF8C4D4, 0x1394428F, 0x9502A112, 0x495C814B}},
    {29, "Segno Amp", "Fx|Distortion", {0x5A5E5968, 0xF68F438D, 0xB6CED6FC, 0x89754BC0}, {0x651D2E8F, 0xC5134060, 0x8FA5E1C2, 0x31C78C28}},
    {30, "Segno Modulation", "Fx|Modulation", {0x4DDE94C0, 0xAC4141EE, 0x95F044CC, 0xB6068D34}, {0x9122F3CD, 0xCC3B4A65, 0x82ECB84B, 0xB37D76EB}},
    {31, "Segno Room reverb", "Fx|Reverb", {0x2F3F3017, 0x29694686, 0x854E4D77, 0x1CA55889}, {0x283C9AA7, 0xA07949FF, 0x8B931DB6, 0x63AE9B15}},
    {32, "Segno Smart Tune", "Fx|Pitch Shift", {0x8F8D32E7, 0xD14E4512, 0x82769C58, 0xCAD79196}, {0xD9C656BF, 0x9AAE4004, 0xB39C0345, 0x80EB7865}},
};
// clang-format on

constexpr int kFxKindCount = sizeof(kFxKinds) / sizeof(kFxKinds[0]);

}  // namespace segno_vst3
