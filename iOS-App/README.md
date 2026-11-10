# Native iPhone and iPad app

Open RecipeApp.xcodeproj and select RecipeMobile. The new target uses the local RecipeCore package with iOS/iPadOS 15 compatibility. No team, provisioning profile or release signing has been selected. Existing Mac signing/release settings are unchanged.

The app provides adaptive NavigationView browsing (list/detail on iPad, navigation on iPhone), collection counts, catalogue/ingredient search and filters, favourites, notes, offline recipe/photos/PDF references, view/cook counts and shared cooking mode. Import a cleaned folder with its images/PDFs using the folder button. For a portable Mac export, import Recipes and Notes separately; do not import Recently deleted unless you want those recipes back. No cloud sync is present.

Validation: shared Swift/Python suites plus an unsigned arm64 iOS Simulator compile and executable link with a 15.0 minimum OS. Scripts/check-ios.sh repeats that compile without launching the app. The restricted session cannot run Simulator or Xcode's nested package sandbox, so an Xcode build and interactive iPhone/iPad tests remain required. Use test recipes, never the live Mac library.

Manual checks: launch on both devices; import twice; browse narrow/wide and rotate; use large accessibility text; search ingredient synonyms and tags; toggle a favourite and relaunch; open a PDF/page; start cooking, check ingredients, rotate, background/foreground and finish; confirm screen-awake resets and cooking count changes once. Device installation/signing is a separate user-controlled step.
