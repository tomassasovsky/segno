/* The interface's input switches (#1646): le_interface_inputs_scan and
 * le_interface_inputs_write against fake cards (test_engine_interface_routing.h)
 * read from real dumps in fixtures/alsa, each citing its source, and built
 * cards for the generic rules. Included by test_engine_core.c after the
 * routing tests. */

#define II_FIXTURES "src/test/fixtures/alsa/"

static void ii_add_bool(rt_card* card, const char* name, unsigned value) {
  rt_ctl* c = &card->ctl[card->count++];
  memset(c, 0, sizeof(*c));
  snprintf(c->name, sizeof(c->name), "%s", name);
  c->mixer = 1;
  c->type = LE_MIXER_BOOLEAN;
  c->value = value;
}

static le_interface_inputs ii_scan(rt_card* card) {
  const le_mixer m = rt_mixer(card);
  le_interface_inputs caps;
  memset(&caps, 0x5a, sizeof(caps));
  le_interface_inputs_scan(&m, &caps);
  return caps;
}

static int32_t ii_write(rt_card* card, int control, int index, int value) {
  const le_mixer m = rt_mixer(card);
  return le_interface_inputs_write(&m, control, index, value);
}

/* Input `n` (1-based) has exactly these switches; -1 for none. */
static void ii_check_input(const le_interface_inputs* caps, int n, int level,
                           int pad, int air, int air_choices,
                           int phantom_group) {
  const le_interface_input* in = &caps->inputs[n - 1];
  CHECK(in->level == level);
  CHECK(in->pad == pad);
  CHECK(in->air == air);
  CHECK(in->air_choices == air_choices);
  CHECK(in->phantom_group == phantom_group);
}

static void ii_check_phantom(const le_interface_inputs* caps, int g, int first,
                             int last, int on) {
  CHECK(g < caps->phantom_count);
  CHECK(caps->phantom[g].first == first);
  CHECK(caps->phantom[g].last == last);
  CHECK(caps->phantom[g].on == on);
}

static void ii_check_none(const le_interface_inputs* caps) {
  CHECK(caps->state == LE_INTERFACE_NO_CONTROLS);
  CHECK(caps->input_count == 0);
  CHECK(caps->phantom_count == 0);
  CHECK(caps->adapter[0] == '\0');
  for (int n = 1; n <= LE_INTERFACE_MAX_INPUTS; ++n) {
    ii_check_input(caps, n, -1, -1, -1, 0, -1);
  }
}

/* The console's 4i4: Inst/Line, Pad and Air on 1-2, one 48 V switch for
 * both; the rear line inputs 3-4 have nothing. */
static void test_inputs_4i4_gen3(void) {
  printf("test_inputs_4i4_gen3\n");
  static rt_card card;
  rt_load(&card, RT_4I4);
  CHECK(card.usb_vendor == 0x1235u && card.usb_product == 0x8212u);
  const le_interface_inputs caps = ii_scan(&card);
  CHECK(caps.state == LE_INTERFACE_CONTROLS);
  CHECK(strcmp(caps.adapter, "scarlett2") == 0);
  CHECK(caps.input_count == 2);
  ii_check_input(&caps, 1, 0, 0, 0, 2, 0);
  ii_check_input(&caps, 2, 0, 0, 0, 2, 0);
  ii_check_input(&caps, 3, -1, -1, -1, 0, -1);
  ii_check_input(&caps, 4, -1, -1, -1, 0, -1);
  CHECK(caps.phantom_count == 1);
  ii_check_phantom(&caps, 0, 1, 2, 1);
  CHECK(card.writes == 0);
}

/* A write changes only its control, is read back, and is skipped when the
 * card already holds the value. */
static void test_inputs_4i4_writes(void) {
  printf("test_inputs_4i4_writes\n");
  static rt_card card;
  rt_load(&card, RT_4I4);
  CHECK(ii_write(&card, LE_INTERFACE_LEVEL, 0, 1) == LE_OK);
  CHECK(strcmp(rt_selected(&card, "Line In 1 Level Capture Enum"), "Inst") ==
        0);
  CHECK(strcmp(rt_selected(&card, "Line In 2 Level Capture Enum"), "Line") ==
        0);
  CHECK(card.writes == 1);
  CHECK(ii_write(&card, LE_INTERFACE_LEVEL, 0, 1) == LE_OK);
  CHECK(card.writes == 1);

  CHECK(ii_write(&card, LE_INTERFACE_PAD, 1, 1) == LE_OK);
  CHECK(rt_value(&card, "Line In 2 Pad Capture Switch") == 1u);
  CHECK(rt_value(&card, "Line In 1 Pad Capture Switch") == 0u);
  CHECK(ii_write(&card, LE_INTERFACE_AIR, 0, 1) == LE_OK);
  CHECK(rt_value(&card, "Line In 1 Air Capture Switch") == 1u);
  CHECK(ii_write(&card, LE_INTERFACE_PHANTOM, 0, 0) == LE_OK);
  CHECK(rt_value(&card, "Line In 1-2 Phantom Power Capture Switch") == 0u);
  CHECK(card.writes == 4);

  le_interface_inputs caps = ii_scan(&card);
  ii_check_input(&caps, 1, 1, 0, 1, 2, 0);
  ii_check_input(&caps, 2, 0, 1, 0, 2, 0);
  ii_check_phantom(&caps, 0, 1, 2, 0);

  /* Switches the card does not have, and values out of range. */
  CHECK(ii_write(&card, LE_INTERFACE_LEVEL, 2, 1) == LE_ERR_INVALID);
  CHECK(ii_write(&card, LE_INTERFACE_AIR, 0, 2) == LE_ERR_INVALID);
  CHECK(ii_write(&card, LE_INTERFACE_PAD, 0, -1) == LE_ERR_INVALID);
  CHECK(ii_write(&card, LE_INTERFACE_PHANTOM, 1, 1) == LE_ERR_INVALID);
  CHECK(ii_write(&card, LE_INTERFACE_SETUP_MODE_OFF, 0, 0) == LE_ERR_INVALID);
  CHECK(ii_write(&card, 99, 0, 0) == LE_ERR_INVALID);
  CHECK(card.writes == 4);
}

/* A write the card refuses, or accepts and does not keep, is an error and
 * leaves the other switches as they were. */
static void test_inputs_refused_writes(void) {
  printf("test_inputs_refused_writes\n");
  static rt_card card;
  rt_load(&card, RT_4I4);
  card.refuse = "Line In 1 Pad Capture Switch";
  card.stuck = "Line In 2 Air Capture Switch";
  CHECK(ii_write(&card, LE_INTERFACE_PAD, 0, 1) == LE_ERR_DEVICE);
  CHECK(ii_write(&card, LE_INTERFACE_AIR, 1, 1) == LE_ERR_DEVICE);
  CHECK(rt_value(&card, "Line In 1 Pad Capture Switch") == 0u);
  CHECK(rt_value(&card, "Line In 2 Air Capture Switch") == 0u);
  CHECK(card.writes == 2);
  const le_interface_inputs caps = ii_scan(&card);
  ii_check_input(&caps, 1, 0, 0, 0, 2, 0);
  ii_check_input(&caps, 2, 0, 0, 0, 2, 0);
  ii_check_phantom(&caps, 0, 1, 2, 1);
}

/* "Line In N" is Segno's input N only while capture channel N records
 * hardware input N; otherwise the card reports nothing rather than describe
 * the wrong jack, and the generic rules do not take it over. */
static void test_inputs_need_pass_through(void) {
  printf("test_inputs_need_pass_through\n");
  static rt_card card;
  rt_load(&card, RT_4I4);
  rt_set(&card, "PCM 01 Capture Enum", "Analogue 2");
  le_interface_inputs caps = ii_scan(&card);
  ii_check_none(&caps);
  CHECK(ii_write(&card, LE_INTERFACE_LEVEL, 0, 1) == LE_ERR_INVALID);
  CHECK(card.writes == 0);
  rt_set(&card, "PCM 01 Capture Enum", "Analogue 1");
  caps = ii_scan(&card);
  CHECK(caps.state == LE_INTERFACE_CONTROLS);
}

/* Solo 3rd Gen: the jack input (2) has Inst/Line, the XLR (1) Air and 48 V.
 * It has no capture routing controls: its routing is fixed. */
static void test_inputs_solo_gen3(void) {
  printf("test_inputs_solo_gen3\n");
  static rt_card card;
  rt_load_state(&card, II_FIXTURES "scarlett_solo_gen3.state");
  CHECK(card.count == 10);
  const le_interface_inputs caps = ii_scan(&card);
  CHECK(caps.state == LE_INTERFACE_CONTROLS);
  CHECK(strcmp(caps.adapter, "scarlett2") == 0);
  CHECK(caps.input_count == 2);
  ii_check_input(&caps, 1, -1, -1, 0, 2, 0);
  ii_check_input(&caps, 2, 0, -1, -1, 0, -1);
  CHECK(caps.phantom_count == 1);
  ii_check_phantom(&caps, 0, 1, 1, 0);
}

static void test_inputs_2i2_gen3(void) {
  printf("test_inputs_2i2_gen3\n");
  static rt_card card;
  rt_load_state(&card, II_FIXTURES "scarlett_2i2_gen3.state");
  const le_interface_inputs caps = ii_scan(&card);
  CHECK(caps.state == LE_INTERFACE_CONTROLS);
  CHECK(caps.input_count == 2);
  ii_check_input(&caps, 1, 0, -1, 0, 2, 0);
  ii_check_input(&caps, 2, 0, -1, 0, 2, 0);
  CHECK(caps.phantom_count == 1);
  ii_check_phantom(&caps, 0, 1, 2, 1);
}

/* 18i20 3rd Gen: Inst/Line on 1-2, Pad and Air on 1-8, two 48 V switches of
 * four. As dumped, its capture records mixes, so it reports nothing until
 * the routing Segno sets at device open (#1046) makes it pass-through. */
static void test_inputs_18i20_gen3(void) {
  printf("test_inputs_18i20_gen3\n");
  static rt_card card;
  rt_load_state(&card, II_FIXTURES "scarlett_18i20_gen3.state");
  le_interface_inputs caps = ii_scan(&card);
  ii_check_none(&caps);

  const le_mixer m = rt_mixer(&card);
  le_routing_report r;
  le_own_scarlett2_routing(&m, RT_BOTH, &r);
  CHECK(r.failed == 0);
  caps = ii_scan(&card);
  CHECK(caps.state == LE_INTERFACE_CONTROLS);
  CHECK(caps.input_count == 8);
  ii_check_input(&caps, 1, 0, 0, 0, 2, 0);
  ii_check_input(&caps, 2, 0, 0, 0, 2, 0);
  for (int n = 3; n <= 8; ++n) {
    ii_check_input(&caps, n, -1, 0, 0, 2, n <= 4 ? 0 : 1);
  }
  ii_check_input(&caps, 9, -1, -1, -1, 0, -1);
  CHECK(caps.phantom_count == 2);
  ii_check_phantom(&caps, 0, 1, 4, 0);
  ii_check_phantom(&caps, 1, 5, 8, 0);

  /* The second switch powers 5-8 only. */
  CHECK(ii_write(&card, LE_INTERFACE_PHANTOM, 1, 1) == LE_OK);
  CHECK(rt_value(&card, "Line In 5-8 Phantom Power Capture Switch") == 1u);
  CHECK(rt_value(&card, "Line In 1-4 Phantom Power Capture Switch") == 0u);
}

/* Solo 4th Gen: Inst/Line on the jack input (1), three-way Air and 48 V on
 * the XLR (2); capture runs through the input DSP, fed by the same inputs. */
static void test_inputs_solo_gen4(void) {
  printf("test_inputs_solo_gen4\n");
  static rt_card card;
  rt_load_state(&card, II_FIXTURES "scarlett_solo_gen4.state");
  CHECK(card.usb_product == 0x8218u);
  const le_interface_inputs caps = ii_scan(&card);
  CHECK(caps.state == LE_INTERFACE_CONTROLS);
  CHECK(caps.input_count == 2);
  ii_check_input(&caps, 1, 0, -1, -1, 0, -1);
  ii_check_input(&caps, 2, -1, -1, 0, 3, 0);
  ii_check_phantom(&caps, 0, 2, 2, 0);

  /* The three-way Air writes the item it names. */
  CHECK(ii_write(&card, LE_INTERFACE_AIR, 1, 2) == LE_OK);
  CHECK(strcmp(rt_selected(&card, "Line In 2 Air Capture Enum"),
               "Presence + Drive") == 0);
  CHECK(ii_write(&card, LE_INTERFACE_AIR, 1, 3) == LE_ERR_INVALID);
}

static void test_inputs_2i2_gen4(void) {
  printf("test_inputs_2i2_gen4\n");
  static rt_card card;
  rt_load_state(&card, II_FIXTURES "scarlett_2i2_gen4.state");
  const le_interface_inputs caps = ii_scan(&card);
  CHECK(caps.state == LE_INTERFACE_CONTROLS);
  CHECK(caps.input_count == 2);
  ii_check_input(&caps, 1, 0, -1, 0, 3, 0);
  ii_check_input(&caps, 2, 0, -1, 0, 3, 0);
  CHECK(caps.phantom_count == 1);
  ii_check_phantom(&caps, 0, 1, 2, 0);
}

/* 4i4 4th Gen: one 48 V switch per input. */
static void test_inputs_4i4_gen4(void) {
  printf("test_inputs_4i4_gen4\n");
  static rt_card card;
  rt_load_state(&card, II_FIXTURES "scarlett_4i4_gen4.state");
  const le_interface_inputs caps = ii_scan(&card);
  CHECK(caps.state == LE_INTERFACE_CONTROLS);
  CHECK(caps.input_count == 2);
  ii_check_input(&caps, 1, 0, -1, 0, 3, 0);
  ii_check_input(&caps, 2, 0, -1, 0, 3, 1);
  CHECK(caps.phantom_count == 2);
  ii_check_phantom(&caps, 0, 1, 1, 0);
  ii_check_phantom(&caps, 1, 2, 2, 0);
}

/* Vocaster Two: 48 V on each mic input and nothing else this page sets (its
 * gain, mute and DSP controls are other kinds). As dumped, it records mixes;
 * Segno's routing makes it pass-through. */
static void test_inputs_vocaster_two(void) {
  printf("test_inputs_vocaster_two\n");
  static rt_card card;
  rt_load_state(&card, II_FIXTURES "vocaster_two.state");
  le_interface_inputs caps = ii_scan(&card);
  ii_check_none(&caps);
  const le_mixer m = rt_mixer(&card);
  le_routing_report r;
  le_own_scarlett2_routing(&m, RT_BOTH, &r);
  CHECK(r.failed == 0);
  caps = ii_scan(&card);
  CHECK(caps.state == LE_INTERFACE_CONTROLS);
  CHECK(strcmp(caps.adapter, "scarlett2") == 0);
  CHECK(caps.input_count == 2);
  ii_check_input(&caps, 1, -1, -1, -1, 0, 0);
  ii_check_input(&caps, 2, -1, -1, -1, 0, 1);
  ii_check_phantom(&caps, 0, 1, 1, 0);
  ii_check_phantom(&caps, 1, 2, 2, 0);
}

/* Scarlett 6i6 1st Gen: Line/Hi-Z and a 10 dB pad on 1-2, from its own
 * table; the generic rules read the same card the same way. */
static void test_inputs_6i6_gen1(void) {
  printf("test_inputs_6i6_gen1\n");
  static rt_card card;
  rt_load_state(&card, II_FIXTURES "scarlett_6i6_gen1.state");
  le_interface_inputs caps = ii_scan(&card);
  CHECK(caps.state == LE_INTERFACE_CONTROLS);
  CHECK(strcmp(caps.adapter, "scarlett") == 0);
  CHECK(caps.input_count == 2);
  ii_check_input(&caps, 1, 0, 0, -1, 0, -1);
  ii_check_input(&caps, 2, 0, 0, -1, 0, -1);
  CHECK(caps.phantom_count == 0);
  CHECK(ii_write(&card, LE_INTERFACE_LEVEL, 1, 1) == LE_OK);
  CHECK(strcmp(rt_selected(&card, "Input 2 Impedance Switch"), "Hi-Z") == 0);
  CHECK(ii_write(&card, LE_INTERFACE_PAD, 0, 1) == LE_OK);
  CHECK(strcmp(rt_selected(&card, "Input 1 Pad Switch"), "-10dB") == 0);

  card.usb_vendor = 0;
  caps = ii_scan(&card);
  CHECK(caps.state == LE_INTERFACE_CONTROLS);
  CHECK(strcmp(caps.adapter, "generic") == 0);
  CHECK(caps.input_count == 2);
  ii_check_input(&caps, 1, 0, 1, -1, 0, -1);
  ii_check_input(&caps, 2, 1, 0, -1, 0, -1);
}

/* Class-compliant interfaces with hardware-only switches, and a desktop
 * codec, expose nothing (its "SPDIF Phantom Jack" is jack sensing on the
 * card interface, not 48 V). */
static void test_inputs_hardware_only_interfaces(void) {
  printf("test_inputs_hardware_only_interfaces\n");
  static rt_card card;
  rt_load(&card, II_FIXTURES "behringer_umc204hd.txt");
  CHECK(card.usb_vendor == 0x1397u && card.count == 11);
  le_interface_inputs caps = ii_scan(&card);
  ii_check_none(&caps);
  static const char* const k_state[] = {
      "motu_m2.state",
      "motu_m4.state",
      "audient_id4.state",
      "hda_generic_alc1220.state",
  };
  for (size_t i = 0; i < sizeof(k_state) / sizeof(k_state[0]); ++i) {
    char path[128];
    snprintf(path, sizeof(path), II_FIXTURES "%s", k_state[i]);
    rt_load_state(&card, path);
    CHECK(card.count > 0);
    caps = ii_scan(&card);
    ii_check_none(&caps);
    CHECK(ii_write(&card, LE_INTERFACE_PHANTOM, 0, 1) == LE_ERR_INVALID);
    CHECK(card.writes == 0);
  }
  CHECK(rt_lookup(&card, "Input Source") != NULL); /* the codec was read */
}

/* A unit in setup (MSD) mode has only its MSD switch. Turning setup mode off
 * keeps the switch, off, until the unit is power-cycled. Another vendor's
 * card with such a switch is not a Focusrite unit. */
static void test_inputs_setup_mode(void) {
  printf("test_inputs_setup_mode\n");
  static rt_card card;
  memset(&card, 0, sizeof(card));
  card.usb_vendor = 0x1235u;
  card.usb_product = 0x8212u;
  ii_add_bool(&card, "MSD Mode Switch", 1);
  le_interface_inputs caps = ii_scan(&card);
  CHECK(caps.state == LE_INTERFACE_SETUP_MODE);
  CHECK(strcmp(caps.adapter, "scarlett2") == 0);
  CHECK(caps.input_count == 0);
  CHECK(ii_write(&card, LE_INTERFACE_LEVEL, 0, 1) == LE_ERR_INVALID);
  CHECK(ii_write(&card, LE_INTERFACE_SETUP_MODE_OFF, 0, 0) == LE_OK);
  CHECK(rt_value(&card, "MSD Mode Switch") == 0u);
  caps = ii_scan(&card);
  CHECK(caps.state == LE_INTERFACE_SETUP_MODE_RESTART);
  CHECK(ii_write(&card, LE_INTERFACE_SETUP_MODE_OFF, 0, 0) == LE_ERR_INVALID);
  CHECK(card.writes == 1);

  /* A refused write is reported. */
  rt_lookup(&card, "MSD Mode Switch")->value = 1;
  card.refuse = "MSD Mode Switch";
  CHECK(ii_write(&card, LE_INTERFACE_SETUP_MODE_OFF, 0, 0) == LE_ERR_DEVICE);

  card.usb_vendor = 0x07fdu;
  caps = ii_scan(&card);
  ii_check_none(&caps);

  /* The 18i20 dump shows the switch (the driver's setup flag) beside its
   * input controls: not setup mode. */
  rt_load_state(&card, II_FIXTURES "scarlett_18i20_gen3.state");
  CHECK(rt_lookup(&card, "MSD Mode Switch") != NULL);
  caps = ii_scan(&card);
  CHECK(caps.state != LE_INTERFACE_SETUP_MODE &&
        caps.state != LE_INTERFACE_SETUP_MODE_RESTART);
}

/* The generic rules keep a control only when it maps to one input. */
static void test_inputs_generic_rules(void) {
  printf("test_inputs_generic_rules\n");
  static rt_card card;
  memset(&card, 0, sizeof(card));
  card.usb_vendor = 0x2708u;
  ii_add_bool(&card, "Mic 1 48V Switch", 1);         /* phantom on 1 */
  ii_add_bool(&card, "Mic-AN2 48V", 0);              /* phantom on 2 */
  ii_add_bool(&card, "Mic 3 Pad Switch", 1);         /* pad on 3 */
  ii_add_bool(&card, "Input 4 Inst Switch", 1);      /* level on 4 */
  rt_add_enum(&card, "Input 5 Hi-Z Enum", "Line|Hi-Z", 0); /* level on 5 */
  ii_add_bool(&card, "Input 6 Air Switch", 0);       /* air on 6 */
  ii_add_bool(&card, "Line In 7-8 Phantom Switch", 1); /* phantom on 7-8 */
  /* Not used: no input number, two numbers, a range for a pad, two kinds, a
   * playback control, items that do not read as off and on, and two
   * controls of one kind for one input. */
  ii_add_bool(&card, "48V Phantom Power On Mic Inputs Switch", 1);
  ii_add_bool(&card, "Mic 9 Pad 10 Switch", 1);
  ii_add_bool(&card, "Line 9-10 Pad Switch", 1);
  ii_add_bool(&card, "Mic 11 Pad Air Switch", 1);
  ii_add_bool(&card, "Mic 12 Phantom Playback Switch", 1);
  rt_add_enum(&card, "Input 13 Impedance Switch", "Low|High", 0);
  rt_add_enum(&card, "Input 14 Pad Switch", "0dB|-10dB|-20dB", 0);
  ii_add_bool(&card, "Mic 15 Pad Switch", 0);
  ii_add_bool(&card, "Mic 15 Pad Capture Switch", 1);
  ii_add_bool(&card, "Mic 16 Gain Switch", 1); /* no kind keyword */

  le_interface_inputs caps = ii_scan(&card);
  CHECK(caps.state == LE_INTERFACE_CONTROLS);
  CHECK(strcmp(caps.adapter, "generic") == 0);
  CHECK(caps.input_count == 8);
  ii_check_input(&caps, 1, -1, -1, -1, 0, 0);
  ii_check_input(&caps, 2, -1, -1, -1, 0, 1);
  ii_check_input(&caps, 3, -1, 1, -1, 0, -1);
  ii_check_input(&caps, 4, 1, -1, -1, 0, -1);
  ii_check_input(&caps, 5, 0, -1, -1, 0, -1);
  ii_check_input(&caps, 6, -1, -1, 0, 2, -1);
  ii_check_input(&caps, 7, -1, -1, -1, 0, 2);
  ii_check_input(&caps, 8, -1, -1, -1, 0, 2);
  for (int n = 9; n <= LE_INTERFACE_MAX_INPUTS; ++n) {
    ii_check_input(&caps, n, -1, -1, -1, 0, -1);
  }
  CHECK(caps.phantom_count == 3);
  ii_check_phantom(&caps, 0, 1, 1, 1);
  ii_check_phantom(&caps, 1, 2, 2, 0);
  ii_check_phantom(&caps, 2, 7, 8, 1);

  /* A generic enumeration writes the item index. */
  CHECK(ii_write(&card, LE_INTERFACE_LEVEL, 4, 1) == LE_OK);
  CHECK(strcmp(rt_selected(&card, "Input 5 Hi-Z Enum"), "Hi-Z") == 0);
  CHECK(ii_write(&card, LE_INTERFACE_PHANTOM, 1, 1) == LE_OK);
  CHECK(rt_value(&card, "Mic-AN2 48V") == 1u);
  CHECK(ii_write(&card, LE_INTERFACE_PAD, 14, 1) == LE_ERR_INVALID);
}
