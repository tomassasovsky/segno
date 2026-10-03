# M3.16 VGV review — model/UI and root composition

No actionable findings in the reviewed scope.

## Checks

- The strict typed target, resolver, catalogue, and localized readout share the named Hear click choices. UI order Off / First recording / Recording / Play & record is distinct from the native enum order; conversion tests use literal values rather than deriving expectations from the converter.
- The three endpoint editors reuse one small presentation widget. Its state records only an unfinished edit's opening normalized value and focus lifetime; it owns no audio or persistence decision. Escape restores the exact opening number, including non-canonical authored endpoints.
- Loop Tempo sends ordinary edits through TempoCubit. Mapping pages update drafts and save through ControlCubit. Neither presentation path imports a data client or calls native commands. The existing AudioEngine test seam is preserved.
- Readiness and capture eligibility are consumed from the owner. Confirmed readout is separate from edit availability: initial unconfirmed state has no selected choice; recovery retains the accepted choice across page remounts while disabled.
- Composition injects the same Tempo owner for mode and volume; session capture uses the shared Click gate and durable mode. Both supported locales contain the new failure/unavailable/capture copy.
- Legacy constructor fixtures inject an explicitly unavailable owner rather than claiming a fictitious accepted mode. Existing assertions are retained.

## Limits

Large existing owner and view files were not treated as reasons for unrelated structural refactors. No new dependency, compatibility path, or generalized transaction framework was required in this partition.

## Review binding and independence

Base: `3025840dd212a86ee1b23c21b6980f0ac4866e20`. Reviewed source-set fingerprint: `9a4c7b6a794a71d7cf33e244e6e6834a32294d4add98a7f7ef07f43b1dda58b1`. The exact 70-file SHA-256 table is in [the VGV report](vgv-model-ui.md#source-binding).

One reviewer applied the four role definitions sequentially. This reviewer authored the runtime/native partition and does **not** certify that partition here. This is an independent review of the other authors' model, presentation, composition, and associated tests, including the final confirmed-selection and endpoint-editor changes. No tests, product edits, or delegation were performed for this review.

The governing behavior is [the approved Hear click plan](../../../plan/2026-10-03-shared-hear-click.md). Whole-candidate bug review, independent execution, final aggregate/static checks, CI, and commit binding remain the coordinator's gates. This report does not assert merge readiness. Pen and golden rendering are separate author visual evidence; screenshot-generator source was reviewed, pixels were not independently revalidated here.

## Source binding

Paths are repository-relative; hashes are SHA-256 of the reviewed current files.

| Path | SHA-256 |
| --- | --- |
| `.github/workflows/main.yaml` | `be703261a3b605a52832d6f95d47a578b6610ffe0b1895e22ac59b6b94135c4e` |
| `lib/app/app_toasts.dart` | `d55c6f8de8a787cb00f6b50752e4c9c4cf326db1c0650881902d21054a6006dd` |
| `lib/app/audio_bootstrap.dart` | `793b4557ffd9a6c8cc5e95f8cab7736ab80af058ffae50b9c3981f9bd5a6d767` |
| `lib/app/view/app.dart` | `40cc977d2e2597ee497e9d8d14b6bc4c8e5fe35b2b585647f2d617e05a4dafc1` |
| `lib/control/binding/binding_labels.dart` | `ee8de71a5dfc0dab081172e5659aec22384ce6fbcb41182976dc70568fe72a4d` |
| `lib/control/binding/control_value_resolver.dart` | `30f9487262d78f2522cd2c93b12442d0323c71a7e9088a3cab451a2cb140ac5b` |
| `lib/control/binding/control_value_target.dart` | `45c742f1de8f04d58e3859fea62a0c874b920a7ea7177f80674984c8b76211d8` |
| `lib/control/binding/expression_catalogue.dart` | `1a05662350c74a9d339b949abd2e310ef0a56e05d0be28dd0b3fb6642515cdbc` |
| `lib/control/view/click_mode_endpoint_choice.dart` | `39fffb4cba78663b6580eb52acfc10618d41a1efb861203661652a2c1f351255` |
| `lib/control/view/control_value_readout.dart` | `3087cabdaed0e9ef21174611fc626c296888898719c58983addae3d7ff791ebd` |
| `lib/control/view/midi_controls/midi_control_cards.dart` | `9744937fa92c0db35857715c517d9964fcc2c6ff3bda555cafa3183afef31b9a` |
| `lib/control/view/midi_controls/midi_controls_page.dart` | `b8a4c2b7884ca23b38104babdfdbdee0b16fd3c669d649276ac3679845aa599c` |
| `lib/control/view/pedal_setup/expression_controls_panel.dart` | `43b5a3b74e9ef8baeee3c8839744e9eb2d49c763602455ec0dd63c089e751fbd` |
| `lib/control/view/pedal_setup/external_controls_editor.dart` | `856772eca505a12ea4373feb05098abeca7e419881aeb113e2ad13dc880dc314` |
| `lib/control/view/pedal_setup/external_pedal_page.dart` | `5da2971ac83bb9d15f946386c021f77c7ca7d6bdb6d1ea081a3d03767925211b` |
| `lib/l10n/arb/app_en.arb` | `6eeaa0a989f931c9399ad19db53ba8eb50406a614fedef19999f24fe17d4085c` |
| `lib/l10n/arb/app_es.arb` | `288095e43480c2d5f03a799db9cc2c088cec4ff4c20e57c0e43861f7f6bd6d0a` |
| `lib/looper/view/loop_settings/loop_tempo_page.dart` | `f3aafbf96cd1f26b18c45828c32a99db94aff2480fdddd829351597869096d47` |
| `lib/looper/view/looper_page.dart` | `fb540786c8da445b6474a8e3772729fee18210dbffc4e5b1d0dd20ecfd98b632` |
| `lib/session/cubit/session_cubit.dart` | `98d994e884f9608c8dcb07177dc0d5dbe88cea2b2f4310518aed536e3e3937b3` |
| `lib/session/session_mapping.dart` | `8870efa81020857bafef7192401b40ca74a2b4b216ed0da170c6506eb3f4ff58` |
| `test/app/audio_bootstrap_test.dart` | `b53e886e1d1df761e833522343329d7648d3fc049be789f79a10c30684d0be54` |
| `test/app/view/app_test.dart` | `1240a0a51f47af6a4577c635c17f720cc1a8ea1107490860cc05b4206566a9dd` |
| `test/control/binding/binding_labels_test.dart` | `aa5aff151a04c302efa010bf07384de01131cb823518435349b8b90e2cbae847` |
| `test/control/binding/control_value_resolver_test.dart` | `eade7f58598f0f276d95dd0cb27d951e1580cffd2ecd8838d2ba89881894dc6d` |
| `test/control/binding/control_value_target_test.dart` | `6580654d575664b8c5722c28d6b6b3a0d0df99c79dba118ce66b81eb5580c667` |
| `test/control/binding/expression_catalogue_test.dart` | `d61da3a90a5225d91f17a6fc8a81e1c35293e0e8436351ecebd38f90acf85968` |
| `test/control/click_dispatch_test.dart` | `21a07a08628a96601286081bfb07ff22ac96128759957ce96c7ec897c7fed0dc` |
| `test/control/click_mode_endpoint_choice_test.dart` | `e833c78ecd93bfa8b8eb25c5947ee581e8224e63a27703e2c2d8aa1621efa86d` |
| `test/control/control_cubit_test.dart` | `12e88f77c0f892f4dffb9ecb8f5fc95313a34b77f9017c1e2b18b12d4804f8eb` |
| `test/control/control_face_test.dart` | `2bf71785bbc85d80c1d7cc3789857849cefc03e0f356b79925f592104b82b9b8` |
| `test/control/decay_dispatch_test.dart` | `cc0a8da318100f3e1e7fb98603c7ed78899427ecc969d6717be3e1f06f08d19c` |
| `test/control/external_controls_page_test.dart` | `f12578fcb415fb5c8d5c45a3292a9bf9f2b0faa35f6820dc92bfe6facc3c376d` |
| `test/control/external_dispatch_test.dart` | `a1fa7896528a43408a20a529b077f5c2246313f11fdb7cd83f5562dcac99d904` |
| `test/control/external_expression_page_test.dart` | `c3acee46cf7ced5010b3ee864704724695dbc808392098b8fed3f7eb4c93f366` |
| `test/control/external_pedal_page_test.dart` | `84716b2dda55234e19a5d94a7b22b7cd9ddf775cb824d02d52b7c9a037e6fc55` |
| `test/control/midi_controls_page_test.dart` | `6bdfaa7b55a30eef87c1ee19afd80fa6685423e2ae29daa1e20df74828cd590a` |
| `test/control/mixer_catalogue_ui_test.dart` | `4a683266132c7ae0b6ccdc3f6b20f9d18a4d60e16cd1d5911e618e6cea512768` |
| `test/control/one_shot_dispatch_test.dart` | `2b919509629ef621d7439fbb8cc0125a42b7a64851aaf39080a6ddc7e45ddc7d` |
| `test/control/pedal_setup_page_test.dart` | `bb82513c81776eb0499d6823781211097d7d7b55b2110e7cc11b8747deab9c44` |
| `test/control/record_length_dispatch_test.dart` | `1cc019c561222d2508448f2fe08632c0440c5f17dfe6fce3700be29fba6e6444` |
| `test/control/record_timing_dispatch_test.dart` | `b9434df304171147ac5853c8241c88e41186c1cb4db927b27632c44ac08c2d48` |
| `test/fuzz/control_sequence_fuzz_test.dart` | `5c6b7258bc046d2eac2cd415d970348900d0c8e357fb2a0e30fe96bdd9a8cd31` |
| `test/helpers/fake_audio_engine.dart` | `e6c10f4144ade7ecb73ead060fa64f1f734a60d9a35fd1e6ef213fd9e5986756` |
| `test/helpers/fake_click_mode_control.dart` | `0f7af3d3a068f524c203d1b7f57f13350eac81454b33b726a4f1fd8bd3b89385` |
| `test/helpers/helpers.dart` | `ad10144f1f7a45b0cda7233dd5ca9efa79eea9f8ec61d800159bc927401d9d25` |
| `test/helpers/mock_click_tempo_cubit.dart` | `d6770e93c3438bfbd5643ad622318ca5fb1c413f3912a26850cd07ebff4f8666` |
| `test/looper/view/loop_settings/loop_settings_test.dart` | `7e60cbbba05d0ee0c86eaff242386a5f87b2221c267073e2655c98b80cf511fa` |
| `test/looper/view/looper_page_test.dart` | `34bdd5c486484458b05afd0d675116e90bd56dd729ff14a6dc2b355c01b6aad9` |
| `test/looper/view/settings_page_test.dart` | `6296d2aef2e854371a020ffb1926cdacc4d455685395ec0b83046b4e1bb8b6ed` |
| `test/looper/view/settings_tray_test.dart` | `ba789a976c20e9813dfb6826de2c96b61702727f00ef23750e90293ee210be3f` |
| `test/looper/view/tracks_view_test.dart` | `e5e716f0c01a2233485de36880c24c2f4ff045afd735dbc2f0459bdb52864e7c` |
| `test/pedal/view/pedal_assignment_page_test.dart` | `e342ac98896af6f4c95f80994aaf73e9d7b9731c9d29dd4abb9c5a81f23968e4` |
| `test/screenshots/control_center_preview_test.dart` | `6ac8c0fdbcf8146facb00a0c2f3e1c1427560114b2027db2246ecfdfd5112aa9` |
| `test/screenshots/external_pedal_screenshots_test.dart` | `d95dceff42154d0d836e334356687865d246aef023f1246373a66be5fbe6af2e` |
| `test/screenshots/loop_settings_screenshots_test.dart` | `6642bc0462abbe6b406c34e1b133a2072cc3b1718f26f75b344ebec3b048bb40` |
| `test/screenshots/midi_controls_screenshots_test.dart` | `1214c9124bf60726bad95100273840d29ebcab0d5bb7d6b4c205bd7d2e6cf493` |
| `test/screenshots/pedal_setup_screenshots_test.dart` | `8bd04052f2f629f0380bfc7671a83d82eada3e6d4055d58ced7e1be61be8cc63` |
| `test/screenshots/settings_screenshots_test.dart` | `c4ad8b9a075adeeb0c46e641179409890d21f26e95331393ac39cd62f73ae727` |
| `test/screenshots/tracks_screenshots_test.dart` | `43a03c8215abbdb04aebec5ccb55bf9add9b10f9e13c8c0092b76de7072bf0b4` |
| `test/session/click_persistence_test.dart` | `e6ed68f2adf203387f27a29d59a8ab95752222ef1b730ca7747fe0d8c7ac746d` |
| `test/session/cubit/session_cubit_test.dart` | `2618691e1a33239132d8b6f8ca13b001bb464051ace304458c38592dd315f049` |
| `test/session/decay_persistence_test.dart` | `efbdedc816273e8f52173fdf464c89676f368fdc9ac0c48dc4e0a2b735bfd684` |
| `test/session/midi_persistence_test.dart` | `49c31d3d7b60282124fcba253bf060ff56e470bbe39c76fdfa346ee2f11169a7` |
| `test/session/one_shot_persistence_test.dart` | `116c2ad03a8e3878ca87be7de7aa8ae0cb8e0d1e10781e06a9d52ef015aa0aa4` |
| `test/session/record_length_persistence_test.dart` | `6ee93aee52a58b8bca3247a9844cfcd4b43e23b50f3457f50809388407ff6a72` |
| `test/session/record_timing_persistence_test.dart` | `783d54cdb1500832a599acecdd608075a0b68013674c4420a000a10ac4ffe758` |
| `test/session/session_fx_roundtrip_test.dart` | `39871807e9fb7b7596cb8abae1f2bdb967b5c4940d7e9eb214fe6e9814d5e298` |
| `test/session/session_layers_roundtrip_test.dart` | `ed9012005f895219cf10aa72d8d849406b16a3dfea3047b2a25b6bf436fa7c46` |
| `test/session/session_mapping_test.dart` | `5a9c0ef139fd997b7d266b4f5aff227c948d233d5e38a6c9d8c9fd3a99eef34f` |
