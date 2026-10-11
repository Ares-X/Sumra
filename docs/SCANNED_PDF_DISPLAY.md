# Scanned PDF contrast

PDF reading automatically enhances scanned text pages. **View → Document Colors → Enhance Scanned Pages** disables or enables it for the document; the choice is saved with its reading position. Existing reading positions default to enabled.

The existing MuPDF display-list owner examines complete, near-full-page raster images once per retained page. A predominantly neutral paper field and sparse, short ink runs identify a text scan. Colored images and continuous-tone photographs retain their appearance. Only neutral display pixels in the qualifying scan receive smooth gamma-2 contrast; black and white remain fixed and gray antialiasing remains graded. Classification uses the complete image so zoomed viewport tiles make the same decision as whole-page rendering.

This is a reading display adjustment. Source PDF bytes, saving, exporting and printing retain the original document. Engineering enhancement remains a separate setting.

The October 11 local check used original B06, page 130 (printed page 126), at width 1200: the fifth-percentile gray moved from 219 to 190, white-paper pixels stayed unchanged, and a 200×200 viewport tile matched the corresponding full-page pixels. Original-file SHA-256 stayed unchanged.

The canonical app then displayed that original page with enhancement enabled by default, disabled, and enabled again. The text visibly darkened while the paper stayed white, including Single Page, Fit Width and Continuous reading. A fresh process restored page 130 and the enabled choice; the stored position has `enhanceScannedPages: true`. These GUI receipts live in `build/validation-other-format-acceptance-20261011/scan-B06-*`, separately from the native pixel measurement and the twelve focused regression tests.
