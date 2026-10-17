//go:build darwin

package main

import (
	"bytes"
	"image/png"
	"unsafe"

	"sync"

	"github.com/ebitengine/purego"
	"github.com/ebitengine/purego/objc"
)

var (
	selAlloc        = objc.RegisterName("alloc")
	selInitUTF8     = objc.RegisterName("initWithUTF8String:")
	selRelease      = objc.RegisterName("release")
	selSymbol       = objc.RegisterName("imageWithSystemSymbolName:accessibilityDescription:")
	selConfig       = objc.RegisterName("configurationWithPointSize:weight:")
	selWithConfig   = objc.RegisterName("imageWithSymbolConfiguration:")
	selTIFF         = objc.RegisterName("TIFFRepresentation")
	selRepWithData  = objc.RegisterName("imageRepWithData:")
	selRepresent    = objc.RegisterName("representationUsingType:properties:")
	selDictionary   = objc.RegisterName("dictionary")
	selBytes        = objc.RegisterName("bytes")
	selLength       = objc.RegisterName("length")
	nsImageClass    objc.ID
	nsConfigClass   objc.ID
	nsBitmapClass   objc.ID
	nsStringClass   objc.ID
	nsDictionaryCls objc.ID
	appKit          sync.Once
)

// loadAppKit makes AppKit's classes available; the app has it loaded already, tests do not.
func loadAppKit() {
	appKit.Do(func() {
		_, _ = purego.Dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", purego.RTLD_GLOBAL|purego.RTLD_NOW)
		nsImageClass = objc.ID(objc.GetClass("NSImage"))
		nsConfigClass = objc.ID(objc.GetClass("NSImageSymbolConfiguration"))
		nsBitmapClass = objc.ID(objc.GetClass("NSBitmapImageRep"))
		nsStringClass = objc.ID(objc.GetClass("NSString"))
		nsDictionaryCls = objc.ID(objc.GetClass("NSDictionary"))
	})
}

// renderSymbol asks AppKit for an SF Symbol drawn at pointSize and returns it as PNG,
// black on transparent, or nil when this macOS has no such symbol.
func renderSymbol(name string, pointSize float64) []byte {
	loadAppKit()
	if nsImageClass == 0 || nsConfigClass == 0 {
		return nil
	}
	str := nsStringClass.Send(selAlloc).Send(selInitUTF8, append([]byte(name), 0))
	defer str.Send(selRelease)
	image := nsImageClass.Send(selSymbol, str, objc.ID(0))
	if image == 0 {
		return nil
	}
	config := objc.Send[objc.ID](nsConfigClass, selConfig, pointSize, float64(0))
	image = image.Send(selWithConfig, config)
	tiff := image.Send(selTIFF)
	if tiff == 0 {
		return nil
	}
	rep := nsBitmapClass.Send(selRepWithData, tiff)
	if rep == 0 {
		return nil
	}
	data := rep.Send(selRepresent, uintptr(4), nsDictionaryCls.Send(selDictionary)) // NSBitmapImageFileTypePNG
	if data == 0 {
		return nil
	}
	length := int(data.Send(selLength))
	encoded := bytes.Clone(unsafe.Slice(objc.Send[*byte](data, selBytes), length))
	if _, err := png.DecodeConfig(bytes.NewReader(encoded)); err != nil {
		return nil
	}
	return encoded
}
