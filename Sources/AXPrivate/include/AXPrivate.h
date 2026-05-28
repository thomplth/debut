#ifndef AXPrivate_h
#define AXPrivate_h

#include <ApplicationServices/ApplicationServices.h>

// AX-to-CG window bridge
extern AXError _AXUIElementGetWindow(AXUIElementRef element, CGWindowID *windowID);

#endif
