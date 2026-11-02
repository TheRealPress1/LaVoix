# Third-party notices

## Clicky (cursor companion)

The look and motion of the Look cursor companion (`Sources/Fluid/Services/Look/LookBuddy.swift`) follow Clicky's `OverlayWindow.swift`:
the blue triangle that trails the pointer (16 points, `#3380FF`, 35 degree lean, offset right of and below the pointer), the five-bar
waveform, the spinner, the arc flight to a target (arc height, duration, ease, scale pulse, glow) and the label that types itself out.
The constants and the flight maths are kept; the drawing is rewritten on Core Animation layers.

Source: https://github.com/farzaa/clicky (commit e71105c, April 2026 code)

```
MIT License

Copyright (c) 2026 Farza

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
