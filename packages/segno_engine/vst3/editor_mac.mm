/*
 * editor_mac.mm — the pedal-face editor on macOS (editor.h): an NSView that
 * draws the face's pictures and turns mouse input into parameter edits.
 *
 * Contents/Resources/faces holds faces.json (the layout, kept by
 * test/vst3_faces) and, for each kind of engine type T, the pictures at 1x
 * and 2x (T@2x.png):
 *
 *   T.png      the background: the face at its defaults, switched off
 *   T_led.png  the LED lit, at the manifest's "led" rectangle
 *   T_i.png    control i's pictures, in rows of "columns": picture k shows
 *              it at setting k / (frames - 1)
 *
 * A knob turns as it is dragged up or down (200 points end to end, five
 * times finer with Shift), a slider follows the pointer along its track, a
 * button row picks the button pressed, a select opens a menu of its
 * positions' names, and the footswitch switches the bypass. A double click
 * on a knob or a slider sets its default. A stepped parameter moves only to
 * its positions.
 */
#import <Cocoa/Cocoa.h>

#include "editor.h"
#include "params.h"

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

using namespace Steinberg;
using namespace Steinberg::Vst;

extern CFBundleRef ghInst; /* this module's bundle (macmain.cpp) */

namespace {

enum class ControlKind { knob, slider, buttons, select, footswitch };

struct FaceControl {
  ControlKind kind;
  ParamID param;
  NSRect rect;
  int frames = 0;
  NSRect track = NSZeroRect;
  std::vector<NSRect> buttons;
  NSArray<NSString*>* names = nil;
  NSArray<NSImage*>* pictures = nil; /* by setting, frames of them */
};

struct Face {
  NSSize size;
  NSImage* background = nil;
  NSRect led;
  NSImage* ledImage = nil;
  std::vector<FaceControl> controls;
};

/* Points of the drag that takes a knob from end to end. */
constexpr double kKnobTravel = 200.0;

NSRect rectFrom(id json) {
  NSArray* a = json;
  if (![a isKindOfClass:[NSArray class]] || a.count != 4) return NSZeroRect;
  return NSMakeRect([a[0] doubleValue], [a[1] doubleValue], [a[2] doubleValue],
                    [a[3] doubleValue]);
}

/* The 1x and 2x pictures of [name] as one image of [size] points, cut into
 * [frames] pictures in rows of [columns] (one picture when frames is 0). */
NSArray<NSImage*>* loadPictures(NSString* dir, NSString* name, NSSize size, int frames,
                                int columns) {
  const int count = frames > 0 ? frames : 1;
  const int perRow = std::min(count, columns);
  NSMutableArray<NSImage*>* pictures = [NSMutableArray arrayWithCapacity:count];
  for (int k = 0; k < count; ++k) [pictures addObject:[[NSImage alloc] initWithSize:size]];
  for (int scale = 1; scale <= 2; ++scale) {
    NSString* file = [NSString
        stringWithFormat:@"%@/%@%@.png", dir, name, scale == 1 ? @"" : @"@2x"];
    NSBitmapImageRep* sheet =
        (NSBitmapImageRep*)[NSBitmapImageRep imageRepWithContentsOfFile:file];
    CGImageRef cg = sheet.CGImage;
    const size_t w = (size_t)std::lround(size.width * scale);
    const size_t h = (size_t)std::lround(size.height * scale);
    const size_t rows = (size_t)((count + perRow - 1) / perRow);
    if (cg == nullptr || CGImageGetWidth(cg) != w * (size_t)perRow ||
        CGImageGetHeight(cg) != h * rows) {
      return nil;
    }
    for (int k = 0; k < count; ++k) {
      CGImageRef cut = CGImageCreateWithImageInRect(
          cg, CGRectMake((CGFloat)(w * (size_t)(k % perRow)),
                         (CGFloat)(h * (size_t)(k / perRow)), w, h));
      NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithCGImage:cut];
      CGImageRelease(cut);
      rep.size = size;
      [pictures[k] addRepresentation:rep];
    }
  }
  return pictures;
}

/* The face of engine type [type] from the bundle's faces, or false. */
bool loadFace(int32_t type, Face& face) {
  if (ghInst == nullptr) return false;
  CFURLRef resources = CFBundleCopyResourcesDirectoryURL(ghInst);
  if (resources == nullptr) return false;
  NSString* dir =
      [[(__bridge NSURL*)resources path] stringByAppendingPathComponent:@"faces"];
  CFRelease(resources);
  NSData* data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"faces.json"]];
  if (data == nil) return false;
  NSDictionary* manifest = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![manifest isKindOfClass:[NSDictionary class]]) return false;
  const int columns = [manifest[@"columns"] intValue];
  NSDictionary* entry = nil;
  for (NSDictionary* f in manifest[@"faces"]) {
    if ([f[@"type"] intValue] == type) entry = f;
  }
  if (entry == nil || columns <= 0) return false;

  NSArray* size = entry[@"size"];
  face.size = NSMakeSize([size[0] doubleValue], [size[1] doubleValue]);
  NSString* stem = [NSString stringWithFormat:@"%d", type];
  face.background = loadPictures(dir, stem, face.size, 0, columns).firstObject;
  face.led = rectFrom(entry[@"led"]);
  face.ledImage = loadPictures(dir, [stem stringByAppendingString:@"_led"], face.led.size, 0,
                               columns)
                      .firstObject;
  if (face.background == nil || face.ledImage == nil) return false;

  int i = 0;
  for (NSDictionary* c in entry[@"controls"]) {
    FaceControl control;
    NSString* kind = c[@"control"];
    if ([kind isEqualToString:@"knob"]) {
      control.kind = ControlKind::knob;
    } else if ([kind isEqualToString:@"slider"]) {
      control.kind = ControlKind::slider;
    } else if ([kind isEqualToString:@"buttons"]) {
      control.kind = ControlKind::buttons;
    } else if ([kind isEqualToString:@"select"]) {
      control.kind = ControlKind::select;
    } else if ([kind isEqualToString:@"footswitch"]) {
      control.kind = ControlKind::footswitch;
    } else {
      return false;
    }
    control.param = (ParamID)[c[@"param"] intValue];
    control.rect = rectFrom(c[@"rect"]);
    control.frames = [c[@"frames"] intValue];
    if (c[@"track"] != nil) control.track = rectFrom(c[@"track"]);
    for (id b in c[@"buttons"]) control.buttons.push_back(rectFrom(b));
    control.names = c[@"names"];
    if (control.frames > 0) {
      control.pictures =
          loadPictures(dir, [NSString stringWithFormat:@"%@_%d", stem, i], control.rect.size,
                       control.frames, columns);
      if (control.pictures == nil) return false;
    }
    face.controls.push_back(control);
    ++i;
  }
  return true;
}

}  // namespace

/* The face, drawn and played. */
@interface SegnoFaceView : NSView
- (instancetype)initWithFace:(Face)face controller:(EditController*)controller;
@end

@implementation SegnoFaceView {
  Face _face;
  EditController* _controller; /* outlives the view: the editor holds it */
  const FaceControl* _dragging;
  double _dragStart; /* the value when the drag began */
  NSPoint _dragFrom;
}

- (instancetype)initWithFace:(Face)face controller:(EditController*)controller {
  self = [super initWithFrame:NSMakeRect(0, 0, face.size.width, face.size.height)];
  if (self) {
    _face = face;
    _controller = controller;
    _dragging = nullptr;
  }
  return self;
}

- (BOOL)isFlipped {
  return YES;
}

- (BOOL)acceptsFirstMouse:(NSEvent*)event {
  return YES;
}

- (double)valueOf:(ParamID)param {
  return _controller->getParamNormalized(param);
}

/* Moves [param] to [value] as the host expects an editor to: the
 * controller's own value, then the host's (inside a beginEdit/endEdit). */
- (void)set:(ParamID)param to:(double)value {
  value = std::clamp(value, 0.0, 1.0);
  if (value == [self valueOf:param]) return;
  _controller->setParamNormalized(param, value);
  _controller->performEdit(param, value);
  [self setNeedsDisplay:YES];
}

- (void)edit:(ParamID)param to:(double)value {
  _controller->beginEdit(param);
  [self set:param to:value];
  _controller->endEdit(param);
}

/* [v] at the nearest of [param]'s positions, when it has any. */
- (double)snap:(double)v param:(ParamID)param {
  ParameterInfo info{};
  if (![self infoOf:param into:info] || info.stepCount == 0) return v;
  const double last = info.stepCount;
  return std::round(std::clamp(v, 0.0, 1.0) * last) / last;
}

- (BOOL)infoOf:(ParamID)param into:(ParameterInfo&)info {
  const int32 n = _controller->getParameterCount();
  for (int32 i = 0; i < n; ++i) {
    if (_controller->getParameterInfo(i, info) == kResultOk && info.id == param) return YES;
  }
  return NO;
}

- (void)drawRect:(NSRect)dirty {
  auto draw = ^(NSImage* image, NSRect rect) {
    [image drawInRect:rect
             fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver
             fraction:1
       respectFlipped:YES
                hints:nil];
  };
  draw(_face.background, self.bounds);
  if ([self valueOf:segno_vst3::kBypassId] < 0.5) draw(_face.ledImage, _face.led);
  for (const FaceControl& c : _face.controls) {
    if (c.pictures == nil || !NSIntersectsRect(c.rect, dirty)) continue;
    const long k = std::lround([self valueOf:c.param] * (c.frames - 1));
    draw(c.pictures[(NSUInteger)std::clamp(k, 0L, (long)c.frames - 1)], c.rect);
  }
}

- (const FaceControl*)controlAt:(NSPoint)p {
  for (const FaceControl& c : _face.controls) {
    if (NSPointInRect(p, c.rect)) return &c;
  }
  return nullptr;
}

- (double)sliderValue:(const FaceControl&)c at:(NSPoint)p {
  return (p.x - NSMinX(c.track)) / NSWidth(c.track);
}

- (void)mouseDown:(NSEvent*)event {
  const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  const FaceControl* c = [self controlAt:p];
  if (c == nullptr) return;
  switch (c->kind) {
    case ControlKind::footswitch:
      [self edit:c->param to:[self valueOf:c->param] < 0.5 ? 1.0 : 0.0];
      return;
    case ControlKind::buttons:
      for (size_t k = 0; k < c->buttons.size(); ++k) {
        if (NSPointInRect(p, c->buttons[k])) {
          [self edit:c->param to:(double)k / (double)(c->buttons.size() - 1)];
        }
      }
      return;
    case ControlKind::select:
      [self openMenu:*c];
      return;
    case ControlKind::knob:
    case ControlKind::slider: {
      ParameterInfo info{};
      if (event.clickCount == 2 && [self infoOf:c->param into:info]) {
        [self edit:c->param to:info.defaultNormalizedValue];
        return;
      }
      _dragging = c;
      _dragStart = [self valueOf:c->param];
      _dragFrom = p;
      _controller->beginEdit(c->param);
      if (c->kind == ControlKind::slider) {
        [self set:c->param to:[self snap:[self sliderValue:*c at:p] param:c->param]];
      }
      return;
    }
  }
}

- (void)mouseDragged:(NSEvent*)event {
  const FaceControl* c = _dragging;
  if (c == nullptr) return;
  const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  double v;
  if (c->kind == ControlKind::slider) {
    v = [self sliderValue:*c at:p];
  } else {
    const double travel =
        (event.modifierFlags & NSEventModifierFlagShift) ? kKnobTravel * 5 : kKnobTravel;
    v = _dragStart + (_dragFrom.y - p.y) / travel;
    if (v < 0.0 || v > 1.0) {
      /* Past an end, the drag starts over from there. */
      v = std::clamp(v, 0.0, 1.0);
      _dragStart = v;
      _dragFrom = p;
    }
  }
  [self set:c->param to:[self snap:v param:c->param]];
}

- (void)mouseUp:(NSEvent*)event {
  if (_dragging == nullptr) return;
  _controller->endEdit(_dragging->param);
  _dragging = nullptr;
}

/* A select's menu, its current position ticked, under the control. */
- (void)openMenu:(const FaceControl&)c {
  NSMenu* menu = [[NSMenu alloc] initWithTitle:@""];
  const NSUInteger n = c.names.count;
  if (n < 2) return;
  const long current = std::lround([self valueOf:c.param] * (double)(n - 1));
  for (NSUInteger k = 0; k < n; ++k) {
    NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:c.names[k]
                                                  action:@selector(picked:)
                                           keyEquivalent:@""];
    item.target = self;
    item.representedObject = @(c.param);
    item.tag = (NSInteger)k;
    item.state = (long)k == current ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:item];
  }
  [menu popUpMenuPositioningItem:menu.itemArray[(NSUInteger)current]
                      atLocation:NSMakePoint(NSMinX(c.rect), NSMaxY(c.rect))
                          inView:self];
}

- (void)picked:(NSMenuItem*)item {
  const ParamID param = (ParamID)[item.representedObject unsignedIntValue];
  const NSUInteger n = item.menu.numberOfItems;
  [self edit:param to:(double)item.tag / (double)(n - 1)];
}

@end

namespace segno_vst3 {

namespace {

/* The IPlugView a host opens: the face's NSView in the host's window. */
class FaceEditor : public EditorView {
 public:
  FaceEditor(EditController* controller, Face face)
      : EditorView(controller), face_(std::move(face)) {
    ViewRect r(0, 0, (int32)face_.size.width, (int32)face_.size.height);
    setRect(r);
  }

  tresult PLUGIN_API isPlatformTypeSupported(FIDString type) SMTG_OVERRIDE {
    return std::string(type) == kPlatformTypeNSView ? kResultTrue : kResultFalse;
  }

  void attachedToParent() SMTG_OVERRIDE {
    view_ = [[SegnoFaceView alloc] initWithFace:face_ controller:getController()];
    [(__bridge NSView*)systemWindow addSubview:view_];
    EditorView::attachedToParent();
  }

  void removedFromParent() SMTG_OVERRIDE {
    [view_ removeFromSuperview];
    view_ = nil;
    EditorView::removedFromParent();
  }

  void refresh() {
    SegnoFaceView* view = view_;
    if (view == nil) return;
    if ([NSThread isMainThread]) {
      [view setNeedsDisplay:YES];
    } else {
      dispatch_async(dispatch_get_main_queue(), ^{
        [view setNeedsDisplay:YES];
      });
    }
  }

 private:
  Face face_;
  SegnoFaceView* view_ = nil;
};

}  // namespace

IPlugView* createFaceEditor(EditController* controller, int32_t type) {
  Face face;
  if (!loadFace(type, face)) return nullptr;
  return new FaceEditor(controller, std::move(face));
}

void refreshFaceEditor(EditorView* editor) {
  static_cast<FaceEditor*>(editor)->refresh();
}

}  // namespace segno_vst3
