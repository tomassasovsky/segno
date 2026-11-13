/*
 * factory.cpp — Segno.vst3's factory: a processor and an edit controller
 * class for every kind in segno_fx_kinds.h, each created with its FxKind.
 */
#include "controller.h"
#include "processor.h"
#include "public.sdk/source/main/pluginfactory.h"
#include "public.sdk/source/vst/vstaudioeffect.h"
#include "segno_fx_kinds.h"

#ifndef SEGNO_VST3_VERSION
#define SEGNO_VST3_VERSION "1.0.0"
#endif

using namespace Steinberg;

bool InitModule() { return true; }
bool DeinitModule() { return true; }

SMTG_EXPORT_SYMBOL IPluginFactory* PLUGIN_API GetPluginFactory() {
  if (gPluginFactory != nullptr) {
    gPluginFactory->addRef();
    return gPluginFactory;
  }
  static PFactoryInfo info("Segno", "https://github.com/tomassasovsky/segno", "",
                           PFactoryInfo::kUnicode);
  gPluginFactory = new CPluginFactory(info);
  for (const segno_vst3::FxKind& kind : segno_vst3::kFxKinds) {
    void* context = const_cast<segno_vst3::FxKind*>(&kind);
    const uint32_t* p = kind.processor;
    const uint32_t* c = kind.controller;
    TUID pid = INLINE_UID(p[0], p[1], p[2], p[3]);
    TUID cid = INLINE_UID(c[0], c[1], c[2], c[3]);
    PClassInfo2 processor(pid, PClassInfo::kManyInstances, kVstAudioEffectClass,
                          kind.name, Vst::kDistributable, kind.subcategory, nullptr,
                          SEGNO_VST3_VERSION, kVstVersionString);
    gPluginFactory->registerClass(&processor, segno_vst3::Processor::createInstance,
                                  context);
    PClassInfo2 controller(cid, PClassInfo::kManyInstances,
                           kVstComponentControllerClass, kind.name, 0, "", nullptr,
                           SEGNO_VST3_VERSION, kVstVersionString);
    gPluginFactory->registerClass(&controller, segno_vst3::Controller::createInstance,
                                  context);
  }
  return gPluginFactory;
}
