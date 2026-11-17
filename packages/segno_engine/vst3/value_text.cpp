#include "value_text.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "params.h"
#include "segno_engine_api.h"

namespace segno_vst3 {

namespace {

/* Dart's round() and the console's: half away from zero. */
long long roundAway(double x) { return std::llround(x); }

std::string whole(double x) { return std::to_string(roundAway(x)); }

/* [x] to [digits] decimals, as the console's decimal pattern (intl's
 * NumberFormat, English) prints it: the sign, then the integer part
 * grouped by thousands and the fraction rounded half away from zero on its
 * own, carrying into the integer part. */
std::string fixed(double x, int digits) {
  const double a = std::fabs(x);
  long long integerPart = (long long)std::floor(a);
  const long long power = (long long)std::pow(10.0, digits);
  long long fraction = roundAway((a - (double)integerPart) * (double)power);
  if (fraction >= power) {
    ++integerPart;
    fraction -= power;
  }
  std::string integer = std::to_string(integerPart);
  for (int i = (int)integer.size() - 3; i > 0; i -= 3) integer.insert((size_t)i, ",");
  char fractionText[24];
  std::snprintf(fractionText, sizeof(fractionText), "%0*lld", digits, fraction);
  return (std::signbit(x) ? "-" : "") + integer + "." + fractionText;
}

/* [x] to [digits] decimals as Dart's toStringAsFixed prints it: from the
 * exact decimal expansion of the double, a tie rounded away from zero (the
 * larger magnitude), whatever the C locale. */
std::string toFixed(double x, int digits) {
  char exact[400];
  std::snprintf(exact, sizeof(exact), "%.300f", std::fabs(x));
  std::string number(exact);
  const size_t point = number.find_first_of(".,");
  std::string kept = number.substr(0, point) + number.substr(point + 1, (size_t)digits);
  if (number[point + 1 + (size_t)digits] >= '5') {
    int i = (int)kept.size() - 1;
    for (; i >= 0 && kept[(size_t)i] == '9'; --i) kept[(size_t)i] = '0';
    if (i < 0) {
      kept.insert(0, "1");
    } else {
      ++kept[(size_t)i];
    }
  }
  const size_t integerDigits = kept.size() - (size_t)digits;
  return (x < 0 ? "-" : "") + kept.substr(0, integerDigits) + "." + kept.substr(integerDigits);
}

/* The shortest decimal that is [f] as a float, as a double: the number
 * the descriptor was written as (0.45 rather than 0.449999988), which is
 * what the console's own table of the descriptors holds. */
double decimalOf(float f) {
  char text[32];
  for (int precision = 1; precision <= 9; ++precision) {
    std::snprintf(text, sizeof(text), "%.*g", precision, (double)f);
    const double d = std::strtod(text, nullptr);
    if ((float)d == f) return d;
  }
  return (double)f;
}

/* A setting's value at normalized [v], mapped as the console maps it: a
 * choice first takes its nearest position. */
double valueAt(const le_fx_param_desc& d, double v) {
  v = std::isnan(v) ? 0.0 : v < 0.0 ? 0.0 : v > 1.0 ? 1.0 : v;
  if (d.unit == LE_FX_UNIT_CHOICE && d.steps > 1) {
    v = std::floor(v * (d.steps - 1) + 0.5) / (d.steps - 1);
  }
  const double lo = decimalOf(d.at_min);
  const double hi = decimalOf(d.at_max);
  switch (d.curve) {
    case LE_FX_CURVE_EXPONENTIAL:
      return lo * std::pow(hi / lo, v);
    case LE_FX_CURVE_RECIPROCAL:
      return 1.0 / (1.0 / lo + (1.0 / hi - 1.0 / lo) * v);
    case LE_FX_CURVE_REVERB_TIME:
      return v >= 1.0 ? hi : std::fmin(hi, (v + lo) / (1.0 - v));
    default:
      return lo + (hi - lo) * v;
  }
}

std::string pitchInterval(double semitones) {
  const long long w = roundAway(semitones);
  if (std::fabs(semitones - (double)w) >= 0.05) {
    return std::string(semitones > 0 ? "+" : "-") +
           fixed((double)roundAway(std::fabs(semitones) * 10) / 10, 1) + " st";
  }
  if (w == 0) return "Unison";
  const std::string sign = w > 0 ? "+" : "-";
  const long long magnitude = w < 0 ? -w : w;
  if (magnitude % 12 == 0) return sign + std::to_string(magnitude / 12) + " oct";
  return sign + std::to_string(magnitude) + " st";
}

template <size_t N>
const char* at(const char* const (&names)[N], int i) {
  return i >= 0 && (size_t)i < N ? names[i] : nullptr;
}

const char* const kPumperRates[] = {"Bar",   "1/2",  "1/2T", "1/4",  "1/4T", "1/8",
                                    "1/8T",  "1/16", "1/16T", "1/32", "1/32T"};
const char* const kSlicerPatterns[] = {
    "AABB",   "ABCC",   "AACD",  "ABC_",  "A_C_", "A_CC",   "A___C___", "ABcccc", "AAccdd",
    "AB__dd", "AA__dd", "ABC<",  "AB_<",  "AA_<", "A_B_C<", "AB<<",     "<<<<"};
const char* const kSlicerSteps[] = {"1/4",   "1/4T", "1/8",   "1/8T", "1/16",
                                    "1/16T", "1/32", "1/32T", "1/64"};
const char* const kLfoRates[] = {"8/4", "6/4",  "5/4", "4/4", "3/4",  "1/1T", "1/2", "1/4D",
                                 "1/2T", "1/4", "1/8D", "1/4T", "1/8", "1/16D", "1/8T", "1/16"};
const char* const kDelayTimes[] = {"1/32", "1/16T", "1/32D", "1/16", "1/8T", "1/16D", "1/8",
                                   "1/4T", "1/8D",  "1/4",   "2/4T", "1/4D", "2/4",   "5/8",
                                   "3/4",  "7/8",   "4/4",   "5/4",  "6/4",  "8/4"};
const char* const kDelayModes[] = {"DIGI",       "DIGI L/R",   "DIGI GRV",   "DAMPED", "DAMPED L/R",
                                   "DAMPED GRV", "RESO LO",    "RES LO L/R", "RES LO GRV",
                                   "RESO HI",    "RES HI L/R", "RES HI GRV", "DRUM",   "DUB"};
const char* const kCabinets[] = {"D.I.",   "BRIT",   "1x8\"",  "1x12\"", "2x10\"", "2x12\"",
                                 "4x10\"", "4x12\"", "1x15\"", "BASS",   "4x10\"", "RADIO"};
const char* const kModModes[] = {"CHORUS", "PHASER", "FLANGER", "Tremolo"};
const char* const kRooms[] = {"HALL",          "STADIUM",       "ROOM",          "BOX",
                              "BOOTH",         "CLUB",          "ROOM",          "SMALL CHAMBER",
                              "Med CHAMBER",   "LARGE CHAMBER", "SMALL STUDIO",  "LARGE STUDIO",
                              "SCORING STAGE", "PHILHARMONIC",  "CONCERT HALL",  "CHURCH"};
const char* const kNotes[] = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"};
const char* const kScaleTypes[] = {"Major",  "Minor",   "Harm Min", "Melo Min",  "Dorian",
                                   "Phrygian", "Lydian", "Mixo",    "Locrian",   "Chromatic",
                                   "Penta",  "Maj Triad", "Min Triad", "Root"};
const char* const kOctaverModes[] = {"Phase Vocoder", "PSOLA"};
const char* const kFormants[] = {"Held", "Follow pitch"};
const char* const kWhammyRanges[] = {"-1 oct", "+1 oct"};
const char* const kOffOn[] = {"Off", "On"};
const char* const kEqLayouts[] = {"Shelves", "Bells, cuts", "Bells"};

/* The name of position [i] of the choice keyed [key], or its 1-based
 * number. */
std::string choiceName(const char* key, int i) {
  struct Names {
    const char* key;
    const char* (*name)(int);
  };
  static const Names kNames[] = {
      {"mode", [](int k) { return at(kOctaverModes, k); }},
      {"formants", [](int k) { return at(kFormants, k); }},
      {"whammy_range", [](int k) { return at(kWhammyRanges, k); }},
      {"pumper_rate", [](int k) { return at(kPumperRates, k); }},
      {"slicer_pattern", [](int k) { return at(kSlicerPatterns, k); }},
      {"slicer_step", [](int k) { return at(kSlicerSteps, k); }},
      {"lfo_rate", [](int k) { return at(kLfoRates, k); }},
      {"delay_time", [](int k) { return at(kDelayTimes, k); }},
      {"delay_mode", [](int k) { return at(kDelayModes, k); }},
      {"cabinet", [](int k) { return at(kCabinets, k); }},
      {"mod_mode", [](int k) { return at(kModModes, k); }},
      {"room", [](int k) { return at(kRooms, k); }},
      {"scale_root", [](int k) { return at(kNotes, k); }},
      {"scale_type", [](int k) { return at(kScaleTypes, k); }},
      {"oct_high_mode", [](int k) { return at(kOffOn, k); }},
      {"layout", [](int k) { return at(kEqLayouts, k); }},
  };
  for (const Names& n : kNames) {
    if (std::strcmp(n.key, key) == 0) {
      if (const char* name = n.name(i)) return name;
    }
  }
  return std::to_string(i + 1);
}

std::string settingText(const le_fx_param_desc& d, double v) {
  if (((d.flags & LE_FX_PARAM_OFF_AT_MIN) && v <= 0.0) ||
      ((d.flags & LE_FX_PARAM_OFF_AT_MAX) && v >= 1.0)) {
    return "Off";
  }
  const double value = valueAt(d, v);
  const double tenths = (double)roundAway(value * 10) / 10;
  if (std::strcmp(d.key, "reference") == 0) return fixed(tenths, 1) + " Hz";
  switch (d.unit) {
    case LE_FX_UNIT_PERCENT:
      return whole(value) + "%";
    case LE_FX_UNIT_MS:
      if (tenths >= 100) return whole(value) + " ms";
      if (value > 0 && value < 0.995) {
        return fixed((double)roundAway(value * 100) / 100, 2) + " ms";
      }
      return fixed(tenths, 1) + " ms";
    case LE_FX_UNIT_HZ:
      if (roundAway(value) >= 1000) return fixed(value / 1000, 1) + " kHz";
      if (tenths >= 100) return whole(value) + " Hz";
      return fixed(tenths, 1) + " Hz";
    case LE_FX_UNIT_SEMITONES:
      return pitchInterval(value);
    case LE_FX_UNIT_TIMES:
      return fixed(value, 1) + "x";
    case LE_FX_UNIT_CHOICE: {
      const double c = std::isnan(v) ? 0.0 : v < 0.0 ? 0.0 : v > 1.0 ? 1.0 : v;
      const int position = d.steps > 1 ? (int)std::floor(c * (d.steps - 1) + 0.5) : 0;
      return choiceName(d.key, position);
    }
    case LE_FX_UNIT_DB:
      return fixed(tenths, 1) + " dB";
    case LE_FX_UNIT_Q:
      return fixed(value, 2);
    case LE_FX_UNIT_SECONDS:
      return fixed(value, 2) + " s";
    case LE_FX_UNIT_RATIO:
      return tenths >= 100 ? whole(value) + ":1" : fixed(tenths, 1) + ":1";
    default:
      return fixed(value, 2);
  }
}

}  // namespace

std::string valueText(int32_t type, uint32_t id, double v) {
  switch (id) {
    case kInputId: {
      static const char* const kInputs[] = {"Stereo", "Left only", "Right only", "Mono sum"};
      return kInputs[inputFromNormalized(v)];
    }
    case kOutputId:
      return outputFromNormalized(v) != 0 ? "Mono" : "Stereo";
    case kEnabledId:
      return enabledFromNormalized(v) != 0 ? "On" : "Off";
    case kPlacementId: {
      // In double, as the console computes it.
      const double placement = v * 2.0 - 1.0;
      if (placement == 0.0) return "Centre";
      return toFixed(placement, 2);
    }
    case kLevelId: {
      const double level = v * (double)kLevelMax;
      if (level <= 0.0) return "Off";
      const double db = 20.0 * std::log(level) / M_LN10;
      return fixed((double)roundAway(db * 10) / 10, 1) + " dB";
    }
    default:
      break;
  }
  le_fx_param_desc d;
  if (le_fx_param_info(type, (int32_t)id, &d) != LE_OK) return std::string();
  return settingText(d, v);
}

}  // namespace segno_vst3
