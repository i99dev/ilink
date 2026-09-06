import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_ar.dart';
import 'app_localizations_en.dart';
import 'app_localizations_ru.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of S
/// returned by `S.of(context)`.
///
/// Applications need to include `S.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: S.localizationsDelegates,
///   supportedLocales: S.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the S.supportedLocales
/// property.
abstract class S {
  S(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static S of(BuildContext context) {
    return Localizations.of<S>(context, S)!;
  }

  static const LocalizationsDelegate<S> delegate = _SDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('ar'),
    Locale('en'),
    Locale('ru'),
  ];

  /// No description provided for @vehicle.
  ///
  /// In en, this message translates to:
  /// **'VEHICLE'**
  String get vehicle;

  /// No description provided for @battery.
  ///
  /// In en, this message translates to:
  /// **'BATTERY'**
  String get battery;

  /// No description provided for @interior.
  ///
  /// In en, this message translates to:
  /// **'INTERIOR'**
  String get interior;

  /// No description provided for @mode.
  ///
  /// In en, this message translates to:
  /// **'MODE'**
  String get mode;

  /// No description provided for @network.
  ///
  /// In en, this message translates to:
  /// **'NETWORK'**
  String get network;

  /// No description provided for @daemon.
  ///
  /// In en, this message translates to:
  /// **'DAEMON'**
  String get daemon;

  /// No description provided for @km.
  ///
  /// In en, this message translates to:
  /// **'km'**
  String get km;

  /// No description provided for @climate.
  ///
  /// In en, this message translates to:
  /// **'CLIMATE'**
  String get climate;

  /// No description provided for @fan.
  ///
  /// In en, this message translates to:
  /// **'FAN'**
  String get fan;

  /// No description provided for @face.
  ///
  /// In en, this message translates to:
  /// **'FACE'**
  String get face;

  /// No description provided for @feet.
  ///
  /// In en, this message translates to:
  /// **'FEET'**
  String get feet;

  /// No description provided for @defrost.
  ///
  /// In en, this message translates to:
  /// **'DEFR'**
  String get defrost;

  /// No description provided for @on.
  ///
  /// In en, this message translates to:
  /// **'ON'**
  String get on;

  /// No description provided for @off.
  ///
  /// In en, this message translates to:
  /// **'OFF'**
  String get off;

  /// No description provided for @windows.
  ///
  /// In en, this message translates to:
  /// **'WINDOWS'**
  String get windows;

  /// No description provided for @windowDriver.
  ///
  /// In en, this message translates to:
  /// **'Driver'**
  String get windowDriver;

  /// No description provided for @windowPassenger.
  ///
  /// In en, this message translates to:
  /// **'Passenger'**
  String get windowPassenger;

  /// No description provided for @windowRearLeft.
  ///
  /// In en, this message translates to:
  /// **'Rear-L'**
  String get windowRearLeft;

  /// No description provided for @windowRearRight.
  ///
  /// In en, this message translates to:
  /// **'Rear-R'**
  String get windowRearRight;

  /// No description provided for @windowSunroof.
  ///
  /// In en, this message translates to:
  /// **'Sunroof'**
  String get windowSunroof;

  /// No description provided for @quickActions.
  ///
  /// In en, this message translates to:
  /// **'QUICK ACTIONS'**
  String get quickActions;

  /// No description provided for @unlock.
  ///
  /// In en, this message translates to:
  /// **'UNLOCK'**
  String get unlock;

  /// No description provided for @lock.
  ///
  /// In en, this message translates to:
  /// **'LOCK'**
  String get lock;

  /// No description provided for @trunk.
  ///
  /// In en, this message translates to:
  /// **'TRUNK'**
  String get trunk;

  /// No description provided for @headlights.
  ///
  /// In en, this message translates to:
  /// **'HEADLIGHTS'**
  String get headlights;

  /// No description provided for @massage.
  ///
  /// In en, this message translates to:
  /// **'MASSAGE'**
  String get massage;

  /// No description provided for @seatHeat.
  ///
  /// In en, this message translates to:
  /// **'SEAT HEAT'**
  String get seatHeat;

  /// No description provided for @seatVent.
  ///
  /// In en, this message translates to:
  /// **'SEAT VENT'**
  String get seatVent;

  /// No description provided for @fragrance.
  ///
  /// In en, this message translates to:
  /// **'FRAGRANCE'**
  String get fragrance;

  /// No description provided for @ambient.
  ///
  /// In en, this message translates to:
  /// **'AMBIENT'**
  String get ambient;

  /// No description provided for @lights.
  ///
  /// In en, this message translates to:
  /// **'LIGHTS'**
  String get lights;

  /// No description provided for @screenHome.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get screenHome;

  /// No description provided for @screenRadio.
  ///
  /// In en, this message translates to:
  /// **'Radio'**
  String get screenRadio;

  /// No description provided for @screenMiniApps.
  ///
  /// In en, this message translates to:
  /// **'Apps'**
  String get screenMiniApps;

  /// No description provided for @screenTv.
  ///
  /// In en, this message translates to:
  /// **'TV'**
  String get screenTv;

  /// No description provided for @railDriverMassage.
  ///
  /// In en, this message translates to:
  /// **'DRIVER MASSAGE'**
  String get railDriverMassage;

  /// No description provided for @railDriverHeat.
  ///
  /// In en, this message translates to:
  /// **'DRIVER HEAT'**
  String get railDriverHeat;

  /// No description provided for @railDriverVent.
  ///
  /// In en, this message translates to:
  /// **'DRIVER VENT'**
  String get railDriverVent;

  /// No description provided for @railAmbientLight.
  ///
  /// In en, this message translates to:
  /// **'AMBIENT LIGHT'**
  String get railAmbientLight;

  /// No description provided for @railExterior.
  ///
  /// In en, this message translates to:
  /// **'EXTERIOR'**
  String get railExterior;

  /// No description provided for @levelMode1.
  ///
  /// In en, this message translates to:
  /// **'MODE 1'**
  String get levelMode1;

  /// No description provided for @levelMode2.
  ///
  /// In en, this message translates to:
  /// **'MODE 2'**
  String get levelMode2;

  /// No description provided for @levelMode3.
  ///
  /// In en, this message translates to:
  /// **'MODE 3'**
  String get levelMode3;

  /// No description provided for @levelLight.
  ///
  /// In en, this message translates to:
  /// **'LIGHT'**
  String get levelLight;

  /// No description provided for @levelMid.
  ///
  /// In en, this message translates to:
  /// **'MID'**
  String get levelMid;

  /// No description provided for @levelDense.
  ///
  /// In en, this message translates to:
  /// **'DENSE'**
  String get levelDense;

  /// No description provided for @levelDim.
  ///
  /// In en, this message translates to:
  /// **'DIM'**
  String get levelDim;

  /// No description provided for @levelHigh.
  ///
  /// In en, this message translates to:
  /// **'HIGH'**
  String get levelHigh;

  /// No description provided for @levelHead.
  ///
  /// In en, this message translates to:
  /// **'HEAD'**
  String get levelHead;

  /// No description provided for @levelFogFront.
  ///
  /// In en, this message translates to:
  /// **'FOG F'**
  String get levelFogFront;

  /// No description provided for @levelFogRear.
  ///
  /// In en, this message translates to:
  /// **'FOG R'**
  String get levelFogRear;

  /// No description provided for @assistantListening.
  ///
  /// In en, this message translates to:
  /// **'Listening…'**
  String get assistantListening;

  /// No description provided for @assistantThinking.
  ///
  /// In en, this message translates to:
  /// **'Thinking…'**
  String get assistantThinking;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @welcome.
  ///
  /// In en, this message translates to:
  /// **'Welcome to Dash'**
  String get welcome;

  /// No description provided for @welcomeHint.
  ///
  /// In en, this message translates to:
  /// **'Point Dash at your backend and car before continuing.'**
  String get welcomeHint;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @required.
  ///
  /// In en, this message translates to:
  /// **'Required'**
  String get required;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @actionCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get actionCancel;

  /// No description provided for @actionDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get actionDone;

  /// No description provided for @actionRun.
  ///
  /// In en, this message translates to:
  /// **'Run'**
  String get actionRun;

  /// No description provided for @actionGotIt.
  ///
  /// In en, this message translates to:
  /// **'Got it'**
  String get actionGotIt;

  /// No description provided for @actionRefresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get actionRefresh;

  /// No description provided for @actionSoon.
  ///
  /// In en, this message translates to:
  /// **'Soon'**
  String get actionSoon;

  /// No description provided for @valueUnknown.
  ///
  /// In en, this message translates to:
  /// **'(unknown)'**
  String get valueUnknown;

  /// No description provided for @valueYes.
  ///
  /// In en, this message translates to:
  /// **'yes'**
  String get valueYes;

  /// No description provided for @valueNo.
  ///
  /// In en, this message translates to:
  /// **'no'**
  String get valueNo;

  /// No description provided for @sectionModelsTitle.
  ///
  /// In en, this message translates to:
  /// **'Voice commands'**
  String get sectionModelsTitle;

  /// No description provided for @sectionModelsSubtitleShort.
  ///
  /// In en, this message translates to:
  /// **'On-device speech'**
  String get sectionModelsSubtitleShort;

  /// No description provided for @sectionLanguageTitle.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get sectionLanguageTitle;

  /// No description provided for @sectionLanguageSubtitleShort.
  ///
  /// In en, this message translates to:
  /// **'App language'**
  String get sectionLanguageSubtitleShort;

  /// No description provided for @sectionAppearanceTitle.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get sectionAppearanceTitle;

  /// No description provided for @sectionAppearanceSubtitleShort.
  ///
  /// In en, this message translates to:
  /// **'Theme + driver side'**
  String get sectionAppearanceSubtitleShort;

  /// No description provided for @appearanceSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get appearanceSystem;

  /// No description provided for @appearanceSystemHelp.
  ///
  /// In en, this message translates to:
  /// **'Match the device\'s light or dark setting.'**
  String get appearanceSystemHelp;

  /// No description provided for @appearanceLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get appearanceLight;

  /// No description provided for @appearanceLightHelp.
  ///
  /// In en, this message translates to:
  /// **'Always use the light palette.'**
  String get appearanceLightHelp;

  /// No description provided for @appearanceDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get appearanceDark;

  /// No description provided for @appearanceDarkHelp.
  ///
  /// In en, this message translates to:
  /// **'Always use the dark dashboard palette — tuned for night driving.'**
  String get appearanceDarkHelp;

  /// No description provided for @appearanceDriverSideTitle.
  ///
  /// In en, this message translates to:
  /// **'Driver side'**
  String get appearanceDriverSideTitle;

  /// No description provided for @appearanceDriverSideLeft.
  ///
  /// In en, this message translates to:
  /// **'Left'**
  String get appearanceDriverSideLeft;

  /// No description provided for @appearanceDriverSideLeftHelp.
  ///
  /// In en, this message translates to:
  /// **'Mic anchors to the bottom-left — for left-hand-drive markets (USA, EU, China).'**
  String get appearanceDriverSideLeftHelp;

  /// No description provided for @appearanceDriverSideRight.
  ///
  /// In en, this message translates to:
  /// **'Right'**
  String get appearanceDriverSideRight;

  /// No description provided for @appearanceDriverSideRightHelp.
  ///
  /// In en, this message translates to:
  /// **'Mic anchors to the bottom-right — for right-hand-drive markets (UK, Australia, Japan, India).'**
  String get appearanceDriverSideRightHelp;

  /// No description provided for @appearanceVoiceSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Voice assistant'**
  String get appearanceVoiceSectionTitle;

  /// No description provided for @appearanceVoiceEnabledLabel.
  ///
  /// In en, this message translates to:
  /// **'Show the assistant'**
  String get appearanceVoiceEnabledLabel;

  /// No description provided for @appearanceVoiceEnabledHelp.
  ///
  /// In en, this message translates to:
  /// **'Off hides every mic surface and turns off voice control. Turn back on whenever you want it.'**
  String get appearanceVoiceEnabledHelp;

  /// No description provided for @sectionThemesTitle.
  ///
  /// In en, this message translates to:
  /// **'Themes'**
  String get sectionThemesTitle;

  /// No description provided for @sectionThemesSubtitleShort.
  ///
  /// In en, this message translates to:
  /// **'Pick a look for your dashboard'**
  String get sectionThemesSubtitleShort;

  /// No description provided for @themesGalleryHeader.
  ///
  /// In en, this message translates to:
  /// **'Choose a theme to restyle the whole dashboard. Built-in themes work offline; more can be added from the store.'**
  String get themesGalleryHeader;

  /// No description provided for @themesBuiltInLabel.
  ///
  /// In en, this message translates to:
  /// **'Built-in'**
  String get themesBuiltInLabel;

  /// No description provided for @themesActiveLabel.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get themesActiveLabel;

  /// No description provided for @themesApplyButton.
  ///
  /// In en, this message translates to:
  /// **'Apply'**
  String get themesApplyButton;

  /// No description provided for @themesBetaLabel.
  ///
  /// In en, this message translates to:
  /// **'BETA'**
  String get themesBetaLabel;

  /// No description provided for @themesEmpty.
  ///
  /// In en, this message translates to:
  /// **'No themes available'**
  String get themesEmpty;

  /// No description provided for @themesLoadError.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load themes'**
  String get themesLoadError;

  /// No description provided for @sectionPrivacyTitle.
  ///
  /// In en, this message translates to:
  /// **'Privacy'**
  String get sectionPrivacyTitle;

  /// No description provided for @sectionPrivacySubtitleShort.
  ///
  /// In en, this message translates to:
  /// **'What this car shares'**
  String get sectionPrivacySubtitleShort;

  /// No description provided for @sectionClusterTitle.
  ///
  /// In en, this message translates to:
  /// **'Cluster apps'**
  String get sectionClusterTitle;

  /// No description provided for @sectionClusterSubtitleShort.
  ///
  /// In en, this message translates to:
  /// **'Apps that open fresh on the driver cluster'**
  String get sectionClusterSubtitleShort;

  /// No description provided for @clusterSectionHeader.
  ///
  /// In en, this message translates to:
  /// **'Some apps can\'t be moved to the driver cluster while running — they relaunch or crash on the screen change. The car opens these fresh on the cluster instead (a new instance). ReVanced-based apps are detected automatically; add any other app you\'ve seen bounce or crash.'**
  String get clusterSectionHeader;

  /// No description provided for @clusterSectionSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search apps'**
  String get clusterSectionSearchHint;

  /// No description provided for @clusterSectionAuto.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get clusterSectionAuto;

  /// No description provided for @clusterSectionAutoHelp.
  ///
  /// In en, this message translates to:
  /// **'Always opened fresh on the cluster (ReVanced-based)'**
  String get clusterSectionAutoHelp;

  /// No description provided for @clusterSectionToggleHelp.
  ///
  /// In en, this message translates to:
  /// **'Open this app fresh on the cluster instead of moving it'**
  String get clusterSectionToggleHelp;

  /// No description provided for @clusterSectionEmpty.
  ///
  /// In en, this message translates to:
  /// **'No apps found'**
  String get clusterSectionEmpty;

  /// No description provided for @clusterSectionError.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load apps'**
  String get clusterSectionError;

  /// No description provided for @sectionAboutTitle.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get sectionAboutTitle;

  /// No description provided for @sectionAboutSubtitleShort.
  ///
  /// In en, this message translates to:
  /// **'Version + build info'**
  String get sectionAboutSubtitleShort;

  /// No description provided for @aboutAppName.
  ///
  /// In en, this message translates to:
  /// **'App'**
  String get aboutAppName;

  /// No description provided for @aboutVersion.
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get aboutVersion;

  /// No description provided for @aboutPackage.
  ///
  /// In en, this message translates to:
  /// **'Package'**
  String get aboutPackage;

  /// No description provided for @aboutDevelopedBy.
  ///
  /// In en, this message translates to:
  /// **'Built by'**
  String get aboutDevelopedBy;

  /// No description provided for @aboutDevelopedByValue.
  ///
  /// In en, this message translates to:
  /// **'CubeTek'**
  String get aboutDevelopedByValue;

  /// No description provided for @aboutSponsoredBy.
  ///
  /// In en, this message translates to:
  /// **'Sponsored by'**
  String get aboutSponsoredBy;

  /// No description provided for @aboutSponsoredByValue.
  ///
  /// In en, this message translates to:
  /// **'QEV'**
  String get aboutSponsoredByValue;

  /// No description provided for @aboutCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get aboutCopy;

  /// No description provided for @aboutCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get aboutCopied;

  /// No description provided for @aboutCheckForUpdates.
  ///
  /// In en, this message translates to:
  /// **'Check for updates'**
  String get aboutCheckForUpdates;

  /// No description provided for @aboutCheckUpToDate.
  ///
  /// In en, this message translates to:
  /// **'No update found. The release feed may be unavailable.'**
  String get aboutCheckUpToDate;

  /// No description provided for @devFlightTestModeLabel.
  ///
  /// In en, this message translates to:
  /// **'Flight test mode'**
  String get devFlightTestModeLabel;

  /// No description provided for @devFlightTestModeSub.
  ///
  /// In en, this message translates to:
  /// **'Show a dedicated Flight test tab on the Mini Apps screen with the beta builds you\'re invited to test. Off by default; turn on once a developer invites you.'**
  String get devFlightTestModeSub;

  /// No description provided for @modelsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Speech recognition runs on this device. Choose a speech model in Appearance settings.'**
  String get modelsSubtitle;

  /// No description provided for @diagnosticsTitle.
  ///
  /// In en, this message translates to:
  /// **'Diagnostics'**
  String get diagnosticsTitle;

  /// No description provided for @diagnosticsAppCard.
  ///
  /// In en, this message translates to:
  /// **'App'**
  String get diagnosticsAppCard;

  /// No description provided for @diagnosticsMaintenanceCard.
  ///
  /// In en, this message translates to:
  /// **'Maintenance'**
  String get diagnosticsMaintenanceCard;

  /// No description provided for @diagnosticsKvVersion.
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get diagnosticsKvVersion;

  /// No description provided for @diagnosticsKvPackage.
  ///
  /// In en, this message translates to:
  /// **'Package'**
  String get diagnosticsKvPackage;

  /// No description provided for @diagnosticsKvName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get diagnosticsKvName;

  /// No description provided for @diagnosticsExportLogs.
  ///
  /// In en, this message translates to:
  /// **'Export logs'**
  String get diagnosticsExportLogs;

  /// No description provided for @diagnosticsExportLogsDesc.
  ///
  /// In en, this message translates to:
  /// **'Coming soon — log buffering not wired yet.'**
  String get diagnosticsExportLogsDesc;

  /// No description provided for @voiceConsentTitle.
  ///
  /// In en, this message translates to:
  /// **'Confirm action'**
  String get voiceConsentTitle;

  /// No description provided for @voiceConsentBody.
  ///
  /// In en, this message translates to:
  /// **'The assistant wants to {action}.'**
  String voiceConsentBody(String action);

  /// No description provided for @voiceConsentAllow.
  ///
  /// In en, this message translates to:
  /// **'Allow'**
  String get voiceConsentAllow;

  /// No description provided for @voiceConsentDeny.
  ///
  /// In en, this message translates to:
  /// **'Deny'**
  String get voiceConsentDeny;

  /// No description provided for @voiceShortcutsFavoritesTitle.
  ///
  /// In en, this message translates to:
  /// **'FAVOURITES'**
  String get voiceShortcutsFavoritesTitle;

  /// No description provided for @voiceShortcutsBrowseRadio.
  ///
  /// In en, this message translates to:
  /// **'Browse'**
  String get voiceShortcutsBrowseRadio;

  /// No description provided for @voiceShortcutsFavoritesEmpty.
  ///
  /// In en, this message translates to:
  /// **'No favourites yet. Open Radio and tap ♡ on a station to pin it here.'**
  String get voiceShortcutsFavoritesEmpty;

  /// No description provided for @voiceShortcutsFavoritesError.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load favourites — pull to refresh.'**
  String get voiceShortcutsFavoritesError;

  /// No description provided for @integrityCheckFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'Integrity check failed'**
  String get integrityCheckFailedTitle;

  /// No description provided for @integrityCheckFailedBody.
  ///
  /// In en, this message translates to:
  /// **'Car commands are paused until the next clean check.'**
  String get integrityCheckFailedBody;

  /// No description provided for @settingsErrorPrefix.
  ///
  /// In en, this message translates to:
  /// **'Settings error: {error}'**
  String settingsErrorPrefix(String error);

  /// No description provided for @saveBarUnsaved.
  ///
  /// In en, this message translates to:
  /// **'Unsaved changes'**
  String get saveBarUnsaved;

  /// No description provided for @saveBarSaved.
  ///
  /// In en, this message translates to:
  /// **'All changes saved'**
  String get saveBarSaved;

  /// No description provided for @radioCategoryFavorites.
  ///
  /// In en, this message translates to:
  /// **'FAVORITES'**
  String get radioCategoryFavorites;

  /// No description provided for @radioFailedToLoad.
  ///
  /// In en, this message translates to:
  /// **'Failed to load stations:\n{error}'**
  String radioFailedToLoad(String error);

  /// No description provided for @radioNoStations.
  ///
  /// In en, this message translates to:
  /// **'No stations available'**
  String get radioNoStations;

  /// No description provided for @radioNoStationsHint.
  ///
  /// In en, this message translates to:
  /// **'Pull to refresh, or open Settings → Diagnostics → Refresh radio list.'**
  String get radioNoStationsHint;

  /// No description provided for @radioNoResults.
  ///
  /// In en, this message translates to:
  /// **'No results for \"{query}\"'**
  String radioNoResults(String query);

  /// No description provided for @radioLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading {name}…'**
  String radioLoading(String name);

  /// No description provided for @radioPlaying.
  ///
  /// In en, this message translates to:
  /// **'Playing {name}'**
  String radioPlaying(String name);

  /// No description provided for @radioPaused.
  ///
  /// In en, this message translates to:
  /// **'Paused — {name}'**
  String radioPaused(String name);

  /// No description provided for @radioError.
  ///
  /// In en, this message translates to:
  /// **'Error: {message}'**
  String radioError(String message);

  /// No description provided for @compatCardProbes.
  ///
  /// In en, this message translates to:
  /// **'PROBES'**
  String get compatCardProbes;

  /// No description provided for @compatCardProbesSub.
  ///
  /// In en, this message translates to:
  /// **'Daemon, identity, and live readStatus.'**
  String get compatCardProbesSub;

  /// No description provided for @compatCardScan.
  ///
  /// In en, this message translates to:
  /// **'SCAN'**
  String get compatCardScan;

  /// No description provided for @compatCardManualPress.
  ///
  /// In en, this message translates to:
  /// **'MANUAL PRESS'**
  String get compatCardManualPress;

  /// No description provided for @compatCardManualPressSub.
  ///
  /// In en, this message translates to:
  /// **'Tap a tile to fire the command, then mark the outcome.'**
  String get compatCardManualPressSub;

  /// No description provided for @compatCardFastActions.
  ///
  /// In en, this message translates to:
  /// **'FAST ACTIONS'**
  String get compatCardFastActions;

  /// No description provided for @compatCardFastActionsSub.
  ///
  /// In en, this message translates to:
  /// **'Fire each action with explicit args. Daemon return code is captured for the report.'**
  String get compatCardFastActionsSub;

  /// No description provided for @compatCardBinderProbes.
  ///
  /// In en, this message translates to:
  /// **'AIDL BINDER PROBES'**
  String get compatCardBinderProbes;

  /// No description provided for @compatCardBinderProbesSub.
  ///
  /// In en, this message translates to:
  /// **'Pre-built service.method transacts. Useful when an action is unknown to the daemon but the binder is up.'**
  String get compatCardBinderProbesSub;

  /// No description provided for @compatCardReport.
  ///
  /// In en, this message translates to:
  /// **'REPORT'**
  String get compatCardReport;

  /// No description provided for @compatProbeDaemonAdb.
  ///
  /// In en, this message translates to:
  /// **'Daemon + ADB'**
  String get compatProbeDaemonAdb;

  /// No description provided for @compatProbeCarIdentity.
  ///
  /// In en, this message translates to:
  /// **'Car identity'**
  String get compatProbeCarIdentity;

  /// No description provided for @compatProbeLiveTelemetry.
  ///
  /// In en, this message translates to:
  /// **'Live telemetry (readStatus)'**
  String get compatProbeLiveTelemetry;

  /// No description provided for @compatProbeReread.
  ///
  /// In en, this message translates to:
  /// **'Re-read'**
  String get compatProbeReread;

  /// No description provided for @compatBenchActionsLoaded.
  ///
  /// In en, this message translates to:
  /// **'Loaded {count} actions from the runtime table.'**
  String compatBenchActionsLoaded(int count);

  /// No description provided for @compatBenchPending.
  ///
  /// In en, this message translates to:
  /// **'Pending — refresh probes to load known actions.'**
  String get compatBenchPending;

  /// No description provided for @compatBenchOk.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get compatBenchOk;

  /// No description provided for @compatBenchFail.
  ///
  /// In en, this message translates to:
  /// **'FAIL'**
  String get compatBenchFail;

  /// No description provided for @compatBenchErr.
  ///
  /// In en, this message translates to:
  /// **'ERR'**
  String get compatBenchErr;

  /// No description provided for @compatBenchTotal.
  ///
  /// In en, this message translates to:
  /// **'{total} run(s) total'**
  String compatBenchTotal(int total);

  /// No description provided for @compatNothingToReport.
  ///
  /// In en, this message translates to:
  /// **'Nothing to report yet — run a scan or fire an action first.'**
  String get compatNothingToReport;

  /// No description provided for @compatKvBenchRuns.
  ///
  /// In en, this message translates to:
  /// **'Bench runs'**
  String get compatKvBenchRuns;

  /// No description provided for @compatKvBinderProbes.
  ///
  /// In en, this message translates to:
  /// **'Binder probes'**
  String get compatKvBinderProbes;

  /// No description provided for @compatScanning.
  ///
  /// In en, this message translates to:
  /// **'Scanning…'**
  String get compatScanning;

  /// No description provided for @compatScanButton.
  ///
  /// In en, this message translates to:
  /// **'Scan'**
  String get compatScanButton;

  /// No description provided for @compatStatReachable.
  ///
  /// In en, this message translates to:
  /// **'Reachable'**
  String get compatStatReachable;

  /// No description provided for @compatStatUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get compatStatUnknown;

  /// No description provided for @compatStatInactive.
  ///
  /// In en, this message translates to:
  /// **'Inactive'**
  String get compatStatInactive;

  /// No description provided for @compatNotesLabel.
  ///
  /// In en, this message translates to:
  /// **'Notes (optional)'**
  String get compatNotesLabel;

  /// No description provided for @compatNotesHint.
  ///
  /// In en, this message translates to:
  /// **'What else should the backend know about this car?'**
  String get compatNotesHint;

  /// No description provided for @compatConfirmDangerTitle.
  ///
  /// In en, this message translates to:
  /// **'Run \"{label}\"?'**
  String compatConfirmDangerTitle(String label);

  /// No description provided for @compatConfirmDangerBody.
  ///
  /// In en, this message translates to:
  /// **'This command moves hardware and should only be used while the car is stationary. Continue?'**
  String get compatConfirmDangerBody;

  /// No description provided for @compatKvVinHash.
  ///
  /// In en, this message translates to:
  /// **'Device ID hash'**
  String get compatKvVinHash;

  /// No description provided for @compatKvWithheld.
  ///
  /// In en, this message translates to:
  /// **'(withheld)'**
  String get compatKvWithheld;

  /// No description provided for @compatKvDevice.
  ///
  /// In en, this message translates to:
  /// **'Device'**
  String get compatKvDevice;

  /// No description provided for @compatKvDilink.
  ///
  /// In en, this message translates to:
  /// **'DiLink hint'**
  String get compatKvDilink;

  /// No description provided for @compatKvDaemonOnline.
  ///
  /// In en, this message translates to:
  /// **'Daemon online'**
  String get compatKvDaemonOnline;

  /// No description provided for @compatKvCommandsProbed.
  ///
  /// In en, this message translates to:
  /// **'Commands probed'**
  String get compatKvCommandsProbed;

  /// No description provided for @compatKvVerdictsRecorded.
  ///
  /// In en, this message translates to:
  /// **'Verdicts recorded'**
  String get compatKvVerdictsRecorded;

  /// No description provided for @cmdDoorLock.
  ///
  /// In en, this message translates to:
  /// **'Lock doors'**
  String get cmdDoorLock;

  /// No description provided for @cmdDoorUnlock.
  ///
  /// In en, this message translates to:
  /// **'Unlock doors'**
  String get cmdDoorUnlock;

  /// No description provided for @cmdDoorTrunkOpen.
  ///
  /// In en, this message translates to:
  /// **'Open trunk'**
  String get cmdDoorTrunkOpen;

  /// No description provided for @cmdDoorTrunkClose.
  ///
  /// In en, this message translates to:
  /// **'Close trunk'**
  String get cmdDoorTrunkClose;

  /// No description provided for @cmdHoodOpen.
  ///
  /// In en, this message translates to:
  /// **'Open hood'**
  String get cmdHoodOpen;

  /// No description provided for @cmdHoodClose.
  ///
  /// In en, this message translates to:
  /// **'Close hood'**
  String get cmdHoodClose;

  /// No description provided for @cmdHoodStop.
  ///
  /// In en, this message translates to:
  /// **'Stop hood'**
  String get cmdHoodStop;

  /// No description provided for @cmdClimatePower.
  ///
  /// In en, this message translates to:
  /// **'Climate power'**
  String get cmdClimatePower;

  /// No description provided for @cmdClimateTemp.
  ///
  /// In en, this message translates to:
  /// **'Set temperature'**
  String get cmdClimateTemp;

  /// No description provided for @cmdClimateFan.
  ///
  /// In en, this message translates to:
  /// **'Fan speed'**
  String get cmdClimateFan;

  /// No description provided for @cmdClimateMode.
  ///
  /// In en, this message translates to:
  /// **'Wind mode'**
  String get cmdClimateMode;

  /// No description provided for @cmdClimateCycle.
  ///
  /// In en, this message translates to:
  /// **'Air recirculation'**
  String get cmdClimateCycle;

  /// No description provided for @cmdClimateDefrostF.
  ///
  /// In en, this message translates to:
  /// **'Front defrost'**
  String get cmdClimateDefrostF;

  /// No description provided for @cmdClimateDefrostR.
  ///
  /// In en, this message translates to:
  /// **'Rear defrost'**
  String get cmdClimateDefrostR;

  /// No description provided for @cmdClimateCompressor.
  ///
  /// In en, this message translates to:
  /// **'AC compressor'**
  String get cmdClimateCompressor;

  /// No description provided for @cmdClimateMaxHot.
  ///
  /// In en, this message translates to:
  /// **'Max heat'**
  String get cmdClimateMaxHot;

  /// No description provided for @cmdClimateMaxCool.
  ///
  /// In en, this message translates to:
  /// **'Max cool'**
  String get cmdClimateMaxCool;

  /// No description provided for @cmdClimateComfortMode.
  ///
  /// In en, this message translates to:
  /// **'Comfort mode'**
  String get cmdClimateComfortMode;

  /// No description provided for @cmdClimateRearLock.
  ///
  /// In en, this message translates to:
  /// **'Rear climate lock'**
  String get cmdClimateRearLock;

  /// No description provided for @cmdComfortMassage.
  ///
  /// In en, this message translates to:
  /// **'Massage'**
  String get cmdComfortMassage;

  /// No description provided for @cmdComfortFragOn.
  ///
  /// In en, this message translates to:
  /// **'Fragrance on'**
  String get cmdComfortFragOn;

  /// No description provided for @cmdComfortFragOff.
  ///
  /// In en, this message translates to:
  /// **'Fragrance off'**
  String get cmdComfortFragOff;

  /// No description provided for @cmdComfortAtmos.
  ///
  /// In en, this message translates to:
  /// **'Ambient lighting'**
  String get cmdComfortAtmos;

  /// No description provided for @cmdWindowFlOpen.
  ///
  /// In en, this message translates to:
  /// **'Driver window open'**
  String get cmdWindowFlOpen;

  /// No description provided for @cmdWindowFlClose.
  ///
  /// In en, this message translates to:
  /// **'Driver window close'**
  String get cmdWindowFlClose;

  /// No description provided for @cmdWindowFlStop.
  ///
  /// In en, this message translates to:
  /// **'Driver window stop'**
  String get cmdWindowFlStop;

  /// No description provided for @cmdWindowFlDown.
  ///
  /// In en, this message translates to:
  /// **'Driver window drop'**
  String get cmdWindowFlDown;

  /// No description provided for @cmdWindowFrOpen.
  ///
  /// In en, this message translates to:
  /// **'Passenger window open'**
  String get cmdWindowFrOpen;

  /// No description provided for @cmdWindowFrClose.
  ///
  /// In en, this message translates to:
  /// **'Passenger window close'**
  String get cmdWindowFrClose;

  /// No description provided for @cmdWindowFrStop.
  ///
  /// In en, this message translates to:
  /// **'Passenger window stop'**
  String get cmdWindowFrStop;

  /// No description provided for @cmdWindowRlOpen.
  ///
  /// In en, this message translates to:
  /// **'Rear-left window open'**
  String get cmdWindowRlOpen;

  /// No description provided for @cmdWindowRlClose.
  ///
  /// In en, this message translates to:
  /// **'Rear-left window close'**
  String get cmdWindowRlClose;

  /// No description provided for @cmdWindowRlStop.
  ///
  /// In en, this message translates to:
  /// **'Rear-left window stop'**
  String get cmdWindowRlStop;

  /// No description provided for @cmdWindowRrOpen.
  ///
  /// In en, this message translates to:
  /// **'Rear-right window open'**
  String get cmdWindowRrOpen;

  /// No description provided for @cmdWindowRrClose.
  ///
  /// In en, this message translates to:
  /// **'Rear-right window close'**
  String get cmdWindowRrClose;

  /// No description provided for @cmdWindowRrStop.
  ///
  /// In en, this message translates to:
  /// **'Rear-right window stop'**
  String get cmdWindowRrStop;

  /// No description provided for @cmdWindowAllOpen.
  ///
  /// In en, this message translates to:
  /// **'Open all windows'**
  String get cmdWindowAllOpen;

  /// No description provided for @cmdWindowAllClose.
  ///
  /// In en, this message translates to:
  /// **'Close all windows'**
  String get cmdWindowAllClose;

  /// No description provided for @cmdSunroofOpen.
  ///
  /// In en, this message translates to:
  /// **'Open sunroof'**
  String get cmdSunroofOpen;

  /// No description provided for @cmdSunroofClose.
  ///
  /// In en, this message translates to:
  /// **'Close sunroof'**
  String get cmdSunroofClose;

  /// No description provided for @cmdSunroofTilt.
  ///
  /// In en, this message translates to:
  /// **'Tilt sunroof'**
  String get cmdSunroofTilt;

  /// No description provided for @cmdSunroofStop.
  ///
  /// In en, this message translates to:
  /// **'Stop sunroof'**
  String get cmdSunroofStop;

  /// No description provided for @cmdSeatHeatDrv.
  ///
  /// In en, this message translates to:
  /// **'Driver seat heat'**
  String get cmdSeatHeatDrv;

  /// No description provided for @cmdSeatHeatPass.
  ///
  /// In en, this message translates to:
  /// **'Passenger seat heat'**
  String get cmdSeatHeatPass;

  /// No description provided for @cmdSeatHeatRl.
  ///
  /// In en, this message translates to:
  /// **'Rear-left seat heat'**
  String get cmdSeatHeatRl;

  /// No description provided for @cmdSeatHeatRr.
  ///
  /// In en, this message translates to:
  /// **'Rear-right seat heat'**
  String get cmdSeatHeatRr;

  /// No description provided for @cmdSeatVentDrv.
  ///
  /// In en, this message translates to:
  /// **'Driver seat vent'**
  String get cmdSeatVentDrv;

  /// No description provided for @cmdSeatVentPass.
  ///
  /// In en, this message translates to:
  /// **'Passenger seat vent'**
  String get cmdSeatVentPass;

  /// No description provided for @cmdSeatVentRl.
  ///
  /// In en, this message translates to:
  /// **'Rear-left seat vent'**
  String get cmdSeatVentRl;

  /// No description provided for @cmdSeatVentRr.
  ///
  /// In en, this message translates to:
  /// **'Rear-right seat vent'**
  String get cmdSeatVentRr;

  /// No description provided for @cmdLightHead.
  ///
  /// In en, this message translates to:
  /// **'Headlights'**
  String get cmdLightHead;

  /// No description provided for @cmdLightHeadOn.
  ///
  /// In en, this message translates to:
  /// **'Headlights on'**
  String get cmdLightHeadOn;

  /// No description provided for @cmdLightHeadOff.
  ///
  /// In en, this message translates to:
  /// **'Headlights off'**
  String get cmdLightHeadOff;

  /// No description provided for @cmdLightFogF.
  ///
  /// In en, this message translates to:
  /// **'Front fog lights'**
  String get cmdLightFogF;

  /// No description provided for @cmdLightFogR.
  ///
  /// In en, this message translates to:
  /// **'Rear fog lights'**
  String get cmdLightFogR;

  /// No description provided for @cmdLightTurnLeft.
  ///
  /// In en, this message translates to:
  /// **'Left signal'**
  String get cmdLightTurnLeft;

  /// No description provided for @cmdLightTurnRight.
  ///
  /// In en, this message translates to:
  /// **'Right signal'**
  String get cmdLightTurnRight;

  /// No description provided for @cmdLightFlash.
  ///
  /// In en, this message translates to:
  /// **'Flash lights'**
  String get cmdLightFlash;

  /// No description provided for @cmdLightFindCar.
  ///
  /// In en, this message translates to:
  /// **'Find car'**
  String get cmdLightFindCar;

  /// No description provided for @cmdRadioPlayByName.
  ///
  /// In en, this message translates to:
  /// **'Play by name'**
  String get cmdRadioPlayByName;

  /// No description provided for @cmdRadioPlayStation.
  ///
  /// In en, this message translates to:
  /// **'Play station'**
  String get cmdRadioPlayStation;

  /// No description provided for @cmdRadioPause.
  ///
  /// In en, this message translates to:
  /// **'Pause radio'**
  String get cmdRadioPause;

  /// No description provided for @cmdRadioResume.
  ///
  /// In en, this message translates to:
  /// **'Resume radio'**
  String get cmdRadioResume;

  /// No description provided for @cmdRadioStop.
  ///
  /// In en, this message translates to:
  /// **'Stop radio'**
  String get cmdRadioStop;

  /// No description provided for @cmdRadioNextFav.
  ///
  /// In en, this message translates to:
  /// **'Next favorite station'**
  String get cmdRadioNextFav;

  /// No description provided for @cmdCarStatus.
  ///
  /// In en, this message translates to:
  /// **'Car status'**
  String get cmdCarStatus;

  /// No description provided for @profileSectionSecurity.
  ///
  /// In en, this message translates to:
  /// **'SECURITY'**
  String get profileSectionSecurity;

  /// No description provided for @profilePinEnableLabel.
  ///
  /// In en, this message translates to:
  /// **'Enable PIN lock'**
  String get profilePinEnableLabel;

  /// No description provided for @profilePinEnableSub.
  ///
  /// In en, this message translates to:
  /// **'Require a 4-digit PIN before opening Profile.'**
  String get profilePinEnableSub;

  /// No description provided for @profilePinChangeLabel.
  ///
  /// In en, this message translates to:
  /// **'Change PIN'**
  String get profilePinChangeLabel;

  /// No description provided for @pinLockTitle.
  ///
  /// In en, this message translates to:
  /// **'Enter PIN'**
  String get pinLockTitle;

  /// No description provided for @pinLockSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Enter your 4-digit PIN to access Profile'**
  String get pinLockSubtitle;

  /// No description provided for @pinLockWrong.
  ///
  /// In en, this message translates to:
  /// **'Wrong PIN — try again'**
  String get pinLockWrong;

  /// No description provided for @pinLockForgotCta.
  ///
  /// In en, this message translates to:
  /// **'Forgot PIN?'**
  String get pinLockForgotCta;

  /// No description provided for @pinLockForgotTitle.
  ///
  /// In en, this message translates to:
  /// **'Reset PIN'**
  String get pinLockForgotTitle;

  /// No description provided for @pinLockForgotBody.
  ///
  /// In en, this message translates to:
  /// **'If you forget this device\'s PIN, clear the app\'s storage in Android Settings. This also removes your local settings and app data.'**
  String get pinLockForgotBody;

  /// No description provided for @pinSetupEnterTitle.
  ///
  /// In en, this message translates to:
  /// **'Set a 4-digit PIN'**
  String get pinSetupEnterTitle;

  /// No description provided for @pinSetupEnterSubtitle.
  ///
  /// In en, this message translates to:
  /// **'You\'ll need this PIN to open Profile.'**
  String get pinSetupEnterSubtitle;

  /// No description provided for @pinSetupConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Confirm PIN'**
  String get pinSetupConfirmTitle;

  /// No description provided for @pinSetupConfirmSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Re-enter the same 4 digits.'**
  String get pinSetupConfirmSubtitle;

  /// No description provided for @pinSetupMismatch.
  ///
  /// In en, this message translates to:
  /// **'PINs didn\'t match — start over'**
  String get pinSetupMismatch;

  /// No description provided for @pinSetupSavedSnack.
  ///
  /// In en, this message translates to:
  /// **'PIN enabled'**
  String get pinSetupSavedSnack;

  /// No description provided for @pinDisabledSnack.
  ///
  /// In en, this message translates to:
  /// **'PIN disabled'**
  String get pinDisabledSnack;

  /// No description provided for @onboardingTitle.
  ///
  /// In en, this message translates to:
  /// **'Welcome to iLINK'**
  String get onboardingTitle;

  /// No description provided for @onboardingSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Pick which features the app may use. You can change these later in Settings.'**
  String get onboardingSubtitle;

  /// No description provided for @onboardingLocaleLabel.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get onboardingLocaleLabel;

  /// No description provided for @onboardingPermissionLocationTitle.
  ///
  /// In en, this message translates to:
  /// **'Location'**
  String get onboardingPermissionLocationTitle;

  /// No description provided for @onboardingPermissionLocationReason.
  ///
  /// In en, this message translates to:
  /// **'So the AI assistant can give you context-aware help — local weather, nearby places, navigation cues.'**
  String get onboardingPermissionLocationReason;

  /// No description provided for @onboardingPermissionMicrophoneTitle.
  ///
  /// In en, this message translates to:
  /// **'Voice assistant'**
  String get onboardingPermissionMicrophoneTitle;

  /// No description provided for @onboardingPermissionMicrophoneReason.
  ///
  /// In en, this message translates to:
  /// **'Lets you tap the mic to lock doors, set climate, ask questions, and more — Premier feature. You can turn it off any time from Settings → Appearance.'**
  String get onboardingPermissionMicrophoneReason;

  /// No description provided for @onboardingPermissionNotificationsTitle.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get onboardingPermissionNotificationsTitle;

  /// No description provided for @onboardingPermissionNotificationsReason.
  ///
  /// In en, this message translates to:
  /// **'So radio playback can show in the car\'s notification panel.'**
  String get onboardingPermissionNotificationsReason;

  /// No description provided for @onboardingPermissionGranted.
  ///
  /// In en, this message translates to:
  /// **'Granted'**
  String get onboardingPermissionGranted;

  /// No description provided for @onboardingPermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Denied'**
  String get onboardingPermissionDenied;

  /// No description provided for @onboardingPermissionSkipped.
  ///
  /// In en, this message translates to:
  /// **'Skipped'**
  String get onboardingPermissionSkipped;

  /// No description provided for @onboardingPermissionUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Browser-handled'**
  String get onboardingPermissionUnavailable;

  /// No description provided for @onboardingWebBanner.
  ///
  /// In en, this message translates to:
  /// **'On web, your browser asks for permissions when you actually use a feature. Your choices below are saved as preferences for when you install the app on a real device.'**
  String get onboardingWebBanner;

  /// No description provided for @onboardingContinue.
  ///
  /// In en, this message translates to:
  /// **'Get started'**
  String get onboardingContinue;

  /// No description provided for @onboardingFinishing.
  ///
  /// In en, this message translates to:
  /// **'Setting up…'**
  String get onboardingFinishing;

  /// No description provided for @onboardingRemoteHelpHint.
  ///
  /// In en, this message translates to:
  /// **'Need the assistant to fix something for you remotely? Open it from Profile → Remote help. You start the session, you can stop it any time.'**
  String get onboardingRemoteHelpHint;

  /// No description provided for @sessionEndedDismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get sessionEndedDismiss;

  /// No description provided for @miniAppsTabStore.
  ///
  /// In en, this message translates to:
  /// **'Store'**
  String get miniAppsTabStore;

  /// No description provided for @miniAppsTabInstalled.
  ///
  /// In en, this message translates to:
  /// **'My Apps'**
  String get miniAppsTabInstalled;

  /// No description provided for @miniAppsTabFlightTest.
  ///
  /// In en, this message translates to:
  /// **'Flight test'**
  String get miniAppsTabFlightTest;

  /// No description provided for @miniAppsTabNativeApps.
  ///
  /// In en, this message translates to:
  /// **'Native Apps'**
  String get miniAppsTabNativeApps;

  /// No description provided for @nativeAppsLoadError.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load apps. Pull to refresh.'**
  String get nativeAppsLoadError;

  /// No description provided for @nativeAppsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No apps available yet.'**
  String get nativeAppsEmpty;

  /// No description provided for @nativeAppsInstall.
  ///
  /// In en, this message translates to:
  /// **'Install'**
  String get nativeAppsInstall;

  /// No description provided for @nativeAppsUpdate.
  ///
  /// In en, this message translates to:
  /// **'Update'**
  String get nativeAppsUpdate;

  /// No description provided for @nativeAppsConsentNote.
  ///
  /// In en, this message translates to:
  /// **'Third-party apps install with your confirmation. iLINK verifies each app before installing.'**
  String get nativeAppsConsentNote;

  /// No description provided for @nativeAppsInstalling.
  ///
  /// In en, this message translates to:
  /// **'Finish installing {app} using the system prompt.'**
  String nativeAppsInstalling(String app);

  /// No description provided for @nativeAppsInstallError.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t install {app}: {error}'**
  String nativeAppsInstallError(String app, String error);

  /// No description provided for @nativeAppsUninstallConfirm.
  ///
  /// In en, this message translates to:
  /// **'Remove {app} from this car? You can reinstall it from the store.'**
  String nativeAppsUninstallConfirm(String app);

  /// No description provided for @nativeAppsUninstalled.
  ///
  /// In en, this message translates to:
  /// **'{app} removed.'**
  String nativeAppsUninstalled(String app);

  /// No description provided for @nativeAppsUninstallFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t remove {app}.'**
  String nativeAppsUninstallFailed(String app);

  /// No description provided for @miniAppsFlightTestEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No active flight tests'**
  String get miniAppsFlightTestEmptyTitle;

  /// No description provided for @miniAppsFlightTestEmptyBody.
  ///
  /// In en, this message translates to:
  /// **'When a developer invites you to a beta build, it appears here. Ask a developer for an invite or read the flight-test guide.'**
  String get miniAppsFlightTestEmptyBody;

  /// No description provided for @miniAppsFlightTestEmptyCta.
  ///
  /// In en, this message translates to:
  /// **'Read the flight-test guide'**
  String get miniAppsFlightTestEmptyCta;

  /// No description provided for @miniAppsFlightTestEmptyOpenDocsFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t open the docs. Visit github.com/i99dev/ilink in a browser.'**
  String get miniAppsFlightTestEmptyOpenDocsFailed;

  /// No description provided for @miniAppsInstall.
  ///
  /// In en, this message translates to:
  /// **'Install'**
  String get miniAppsInstall;

  /// No description provided for @miniAppsUninstall.
  ///
  /// In en, this message translates to:
  /// **'Uninstall'**
  String get miniAppsUninstall;

  /// No description provided for @miniAppsEmptyStore.
  ///
  /// In en, this message translates to:
  /// **'No apps available yet. Pull to refresh.'**
  String get miniAppsEmptyStore;

  /// No description provided for @miniAppsEmptyInstalled.
  ///
  /// In en, this message translates to:
  /// **'No apps installed yet. Browse the Store to add some.'**
  String get miniAppsEmptyInstalled;

  /// No description provided for @favoritesTitle.
  ///
  /// In en, this message translates to:
  /// **'FAVOURITES'**
  String get favoritesTitle;

  /// No description provided for @favoritesEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Long-press any mini-app and tap \"Add to favourites\" to pin it here.'**
  String get favoritesEmptyHint;

  /// No description provided for @miniAppsLoadError.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load the catalog. Pull to refresh.'**
  String get miniAppsLoadError;

  /// No description provided for @miniAppsSafeWhileDrivingBadge.
  ///
  /// In en, this message translates to:
  /// **'Safe while driving'**
  String get miniAppsSafeWhileDrivingBadge;

  /// No description provided for @miniAppsDrivingBlockedOk.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get miniAppsDrivingBlockedOk;

  /// No description provided for @miniAppsCouldNotOpen.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t open this mini-app.'**
  String get miniAppsCouldNotOpen;

  /// No description provided for @miniAppsAddToHomeScreen.
  ///
  /// In en, this message translates to:
  /// **'Add to Home Screen'**
  String get miniAppsAddToHomeScreen;

  /// No description provided for @miniAppsAddToHomeScreenSuccess.
  ///
  /// In en, this message translates to:
  /// **'Added {name} to your home screen'**
  String miniAppsAddToHomeScreenSuccess(String name);

  /// No description provided for @miniAppsAddToHomeScreenPartial.
  ///
  /// In en, this message translates to:
  /// **'Added {name} with a default icon'**
  String miniAppsAddToHomeScreenPartial(String name);

  /// No description provided for @miniAppsAddToHomeScreenRefused.
  ///
  /// In en, this message translates to:
  /// **'Your launcher declined the shortcut'**
  String get miniAppsAddToHomeScreenRefused;

  /// No description provided for @miniAppsAddToHomeScreenError.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t add this mini-app to the home screen'**
  String get miniAppsAddToHomeScreenError;

  /// No description provided for @miniAppsDeepLinkUnknownApp.
  ///
  /// In en, this message translates to:
  /// **'This mini-app is no longer available'**
  String get miniAppsDeepLinkUnknownApp;

  /// No description provided for @miniAppsBetaBadge.
  ///
  /// In en, this message translates to:
  /// **'BETA'**
  String get miniAppsBetaBadge;

  /// No description provided for @miniAppsBetaSheetTitle.
  ///
  /// In en, this message translates to:
  /// **'Beta App'**
  String get miniAppsBetaSheetTitle;

  /// No description provided for @miniAppsBetaSheetBody.
  ///
  /// In en, this message translates to:
  /// **'This app is a beta version provided by the developer. It has not been reviewed by iLINK and may behave unexpectedly. Privileged actions are limited to those already approved on the public version.'**
  String get miniAppsBetaSheetBody;

  /// No description provided for @miniAppsBetaSheetReleaseNotesLabel.
  ///
  /// In en, this message translates to:
  /// **'Release notes'**
  String get miniAppsBetaSheetReleaseNotesLabel;

  /// No description provided for @miniAppsBetaSheetContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get miniAppsBetaSheetContinue;

  /// No description provided for @miniAppsFlightTestBadge.
  ///
  /// In en, this message translates to:
  /// **'FLIGHT TEST'**
  String get miniAppsFlightTestBadge;

  /// No description provided for @miniAppsPrivilegedBadge.
  ///
  /// In en, this message translates to:
  /// **'PRIVILEGED'**
  String get miniAppsPrivilegedBadge;

  /// No description provided for @miniAppsFlightTestReleaseNotesTitle.
  ///
  /// In en, this message translates to:
  /// **'What\'s new in this flight test'**
  String get miniAppsFlightTestReleaseNotesTitle;

  /// No description provided for @miniAppsBuildIdentifier.
  ///
  /// In en, this message translates to:
  /// **'v{version} · build {bundleShaPrefix}'**
  String miniAppsBuildIdentifier(String version, String bundleShaPrefix);

  /// No description provided for @otaUpdateAvailableTitle.
  ///
  /// In en, this message translates to:
  /// **'Update available'**
  String get otaUpdateAvailableTitle;

  /// No description provided for @otaUpdateRequiredTitle.
  ///
  /// In en, this message translates to:
  /// **'Required update'**
  String get otaUpdateRequiredTitle;

  /// No description provided for @otaInstallNow.
  ///
  /// In en, this message translates to:
  /// **'Install now'**
  String get otaInstallNow;

  /// No description provided for @otaLater.
  ///
  /// In en, this message translates to:
  /// **'Later'**
  String get otaLater;

  /// No description provided for @otaExitApp.
  ///
  /// In en, this message translates to:
  /// **'Exit app'**
  String get otaExitApp;

  /// No description provided for @otaDownloadFailed.
  ///
  /// In en, this message translates to:
  /// **'Download failed. Tap \"Install now\" to retry.'**
  String get otaDownloadFailed;

  /// No description provided for @homeTabAppsLabel.
  ///
  /// In en, this message translates to:
  /// **'Apps'**
  String get homeTabAppsLabel;

  /// No description provided for @homeTabMiniappsLabel.
  ///
  /// In en, this message translates to:
  /// **'Miniapps'**
  String get homeTabMiniappsLabel;

  /// No description provided for @installedAppsTitle.
  ///
  /// In en, this message translates to:
  /// **'APPS'**
  String get installedAppsTitle;

  /// No description provided for @installedAppsEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'No apps installed on this car.'**
  String get installedAppsEmptyHint;

  /// No description provided for @installedAppsLaunchFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t launch this app.'**
  String get installedAppsLaunchFailed;

  /// No description provided for @toolsNetworkLabel.
  ///
  /// In en, this message translates to:
  /// **'Network'**
  String get toolsNetworkLabel;

  /// No description provided for @toolsNetworkRefresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get toolsNetworkRefresh;

  /// No description provided for @toolsNetworkWifi.
  ///
  /// In en, this message translates to:
  /// **'WiFi'**
  String get toolsNetworkWifi;

  /// No description provided for @toolsNetworkWifiOnNoSsid.
  ///
  /// In en, this message translates to:
  /// **'On'**
  String get toolsNetworkWifiOnNoSsid;

  /// No description provided for @toolsNetworkWifiOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get toolsNetworkWifiOff;

  /// No description provided for @toolsNetworkCellular.
  ///
  /// In en, this message translates to:
  /// **'Cellular Data'**
  String get toolsNetworkCellular;

  /// No description provided for @toolsNetworkCellularOn.
  ///
  /// In en, this message translates to:
  /// **'On'**
  String get toolsNetworkCellularOn;

  /// No description provided for @toolsNetworkCellularOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get toolsNetworkCellularOff;

  /// No description provided for @toolsNetworkRoaming.
  ///
  /// In en, this message translates to:
  /// **'Data Roaming'**
  String get toolsNetworkRoaming;

  /// No description provided for @toolsNetworkRoamingOn.
  ///
  /// In en, this message translates to:
  /// **'On'**
  String get toolsNetworkRoamingOn;

  /// No description provided for @toolsNetworkRoamingOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get toolsNetworkRoamingOff;

  /// No description provided for @toolsNetworkBluetooth.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth'**
  String get toolsNetworkBluetooth;

  /// No description provided for @toolsNetworkBluetoothOnNoDevice.
  ///
  /// In en, this message translates to:
  /// **'On'**
  String get toolsNetworkBluetoothOnNoDevice;

  /// No description provided for @toolsNetworkBluetoothOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get toolsNetworkBluetoothOff;

  /// No description provided for @toolsNetworkHotspot.
  ///
  /// In en, this message translates to:
  /// **'Hotspot'**
  String get toolsNetworkHotspot;

  /// No description provided for @toolsNetworkHotspotOn.
  ///
  /// In en, this message translates to:
  /// **'On'**
  String get toolsNetworkHotspotOn;

  /// No description provided for @toolsNetworkHotspotOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get toolsNetworkHotspotOff;

  /// No description provided for @toolsDoctorLabel.
  ///
  /// In en, this message translates to:
  /// **'Doctor'**
  String get toolsDoctorLabel;

  /// No description provided for @toolsFabLabel.
  ///
  /// In en, this message translates to:
  /// **'FAB'**
  String get toolsFabLabel;

  /// No description provided for @toolsNavHudLabel.
  ///
  /// In en, this message translates to:
  /// **'Nav-HUD'**
  String get toolsNavHudLabel;

  /// No description provided for @toolsWorkflowLabel.
  ///
  /// In en, this message translates to:
  /// **'Automations'**
  String get toolsWorkflowLabel;

  /// No description provided for @toolsDoctorTitle.
  ///
  /// In en, this message translates to:
  /// **'Dashboard Doctor'**
  String get toolsDoctorTitle;

  /// No description provided for @doctorSubtitle.
  ///
  /// In en, this message translates to:
  /// **'One-tap fixes for a sluggish or unresponsive dashboard.'**
  String get doctorSubtitle;

  /// No description provided for @doctorCloseAppsLabel.
  ///
  /// In en, this message translates to:
  /// **'Close other apps'**
  String get doctorCloseAppsLabel;

  /// No description provided for @doctorCloseAppsWhy.
  ///
  /// In en, this message translates to:
  /// **'Force-stops other apps to free memory and recover a sluggish head unit. iLINK keeps running.'**
  String get doctorCloseAppsWhy;

  /// No description provided for @doctorClearClusterLabel.
  ///
  /// In en, this message translates to:
  /// **'Clear cluster'**
  String get doctorClearClusterLabel;

  /// No description provided for @doctorClearClusterWhy.
  ///
  /// In en, this message translates to:
  /// **'Clears frozen or leftover apps from the instrument-cluster display.'**
  String get doctorClearClusterWhy;

  /// No description provided for @doctorWakeDaemonLabel.
  ///
  /// In en, this message translates to:
  /// **'Wake car service'**
  String get doctorWakeDaemonLabel;

  /// No description provided for @doctorWakeDaemonWhy.
  ///
  /// In en, this message translates to:
  /// **'Wakes the car-control service so voice commands can control the car — use if a voice action doesn\'t work right after launch.'**
  String get doctorWakeDaemonWhy;

  /// No description provided for @doctorRunning.
  ///
  /// In en, this message translates to:
  /// **'Working…'**
  String get doctorRunning;

  /// No description provided for @doctorActionDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get doctorActionDone;

  /// No description provided for @doctorActionFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t complete'**
  String get doctorActionFailed;

  /// No description provided for @doctorCloseAppsResult.
  ///
  /// In en, this message translates to:
  /// **'Closed {count} apps'**
  String doctorCloseAppsResult(int count);

  /// No description provided for @appActionsSheetTitle.
  ///
  /// In en, this message translates to:
  /// **'Manage'**
  String get appActionsSheetTitle;

  /// No description provided for @appActionEnable.
  ///
  /// In en, this message translates to:
  /// **'Enable'**
  String get appActionEnable;

  /// No description provided for @appActionDisable.
  ///
  /// In en, this message translates to:
  /// **'Disable'**
  String get appActionDisable;

  /// No description provided for @appActionDisableConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Disable {label}?'**
  String appActionDisableConfirmTitle(Object label);

  /// No description provided for @appActionDisableConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'This app will stop appearing in the launcher and won\'t auto-start. You can re-enable it any time.'**
  String get appActionDisableConfirmBody;

  /// No description provided for @appActionUninstall.
  ///
  /// In en, this message translates to:
  /// **'Uninstall'**
  String get appActionUninstall;

  /// No description provided for @appActionUninstallConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Uninstall {label}?'**
  String appActionUninstallConfirmTitle(Object label);

  /// No description provided for @appActionUninstallConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'Removing this app deletes its local data. Re-installing won\'t restore it. Type the word UNINSTALL to confirm.'**
  String get appActionUninstallConfirmBody;

  /// No description provided for @appActionUninstallTokenHint.
  ///
  /// In en, this message translates to:
  /// **'Type UNINSTALL (English, all caps)'**
  String get appActionUninstallTokenHint;

  /// No description provided for @appActionTransfer.
  ///
  /// In en, this message translates to:
  /// **'Move'**
  String get appActionTransfer;

  /// No description provided for @appActionForceStop.
  ///
  /// In en, this message translates to:
  /// **'Force stop'**
  String get appActionForceStop;

  /// No description provided for @appActionClearData.
  ///
  /// In en, this message translates to:
  /// **'Clear data'**
  String get appActionClearData;

  /// No description provided for @appActionClearDataConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear data for {label}?'**
  String appActionClearDataConfirmTitle(Object label);

  /// No description provided for @appActionClearDataConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'All local data — accounts, settings, cache — will be erased. The app stays installed.'**
  String get appActionClearDataConfirmBody;

  /// No description provided for @appActionClearDataTokenHint.
  ///
  /// In en, this message translates to:
  /// **'Type CLEAR (English, all caps)'**
  String get appActionClearDataTokenHint;

  /// No description provided for @appActionWhitelist.
  ///
  /// In en, this message translates to:
  /// **'Whitelist'**
  String get appActionWhitelist;

  /// No description provided for @appActionConfirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get appActionConfirm;

  /// No description provided for @appActionCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get appActionCancel;

  /// No description provided for @appActionToastOk.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get appActionToastOk;

  /// No description provided for @appActionToastFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t apply'**
  String get appActionToastFailed;

  /// No description provided for @homeRunningAppStop.
  ///
  /// In en, this message translates to:
  /// **'Stop app'**
  String get homeRunningAppStop;

  /// No description provided for @homeRunningAppForceStopSub.
  ///
  /// In en, this message translates to:
  /// **'Force-stop {label}'**
  String homeRunningAppForceStopSub(String label);

  /// No description provided for @voiceAccessOpenSettings.
  ///
  /// In en, this message translates to:
  /// **'Open Settings'**
  String get voiceAccessOpenSettings;

  /// No description provided for @voiceAccessMicPermissionBody.
  ///
  /// In en, this message translates to:
  /// **'The voice assistant needs microphone access to listen.'**
  String get voiceAccessMicPermissionBody;

  /// No description provided for @voiceAccessMicTitle.
  ///
  /// In en, this message translates to:
  /// **'Microphone access is off'**
  String get voiceAccessMicTitle;

  /// No description provided for @voiceAccessMicPermanentlyDeniedBody.
  ///
  /// In en, this message translates to:
  /// **'You previously denied microphone access. Open Settings to grant it.'**
  String get voiceAccessMicPermanentlyDeniedBody;

  /// No description provided for @actionClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get actionClose;

  /// No description provided for @actionDismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get actionDismiss;

  /// No description provided for @miniAppActionsUpdateAvailable.
  ///
  /// In en, this message translates to:
  /// **'Update available'**
  String get miniAppActionsUpdateAvailable;

  /// No description provided for @miniAppActionsReinstallToUpgrade.
  ///
  /// In en, this message translates to:
  /// **'Reinstall to upgrade'**
  String get miniAppActionsReinstallToUpgrade;

  /// No description provided for @miniAppActionsUpdated.
  ///
  /// In en, this message translates to:
  /// **'Updated {name}'**
  String miniAppActionsUpdated(String name);

  /// No description provided for @miniAppActionsOpenHere.
  ///
  /// In en, this message translates to:
  /// **'Open here'**
  String get miniAppActionsOpenHere;

  /// No description provided for @miniAppActionsOnThisScreen.
  ///
  /// In en, this message translates to:
  /// **'On this screen'**
  String get miniAppActionsOnThisScreen;

  /// No description provided for @miniAppActionsOpening.
  ///
  /// In en, this message translates to:
  /// **'Opening {name} on {target}…'**
  String miniAppActionsOpening(String name, String target);

  /// No description provided for @miniAppActionsFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed: {code}'**
  String miniAppActionsFailed(String code);

  /// No description provided for @miniAppStoreUpdatesFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed: {error}'**
  String miniAppStoreUpdatesFailed(String error);

  /// No description provided for @miniAppStoreUpToDate.
  ///
  /// In en, this message translates to:
  /// **'All apps up to date'**
  String get miniAppStoreUpToDate;

  /// No description provided for @miniAppStoreUpdatesList.
  ///
  /// In en, this message translates to:
  /// **'Updates: {names}'**
  String miniAppStoreUpdatesList(String names);

  /// No description provided for @miniAppStoreUpdatesAvailableTitle.
  ///
  /// In en, this message translates to:
  /// **'Updates available'**
  String get miniAppStoreUpdatesAvailableTitle;

  /// No description provided for @miniAppStoreUpdatesTip.
  ///
  /// In en, this message translates to:
  /// **'Tap \"Reinstall\" on My Apps to update'**
  String get miniAppStoreUpdatesTip;

  /// No description provided for @aboutOpenDiagnostics.
  ///
  /// In en, this message translates to:
  /// **'Open diagnostics'**
  String get aboutOpenDiagnostics;

  /// No description provided for @vehicleSupportLabel.
  ///
  /// In en, this message translates to:
  /// **'Vehicle support'**
  String get vehicleSupportLabel;

  /// No description provided for @vehicleSupportTierFull.
  ///
  /// In en, this message translates to:
  /// **'Full integration'**
  String get vehicleSupportTierFull;

  /// No description provided for @vehicleSupportTierStock.
  ///
  /// In en, this message translates to:
  /// **'Stock APIs only'**
  String get vehicleSupportTierStock;

  /// No description provided for @vehicleSupportTierUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Unsupported'**
  String get vehicleSupportTierUnsupported;

  /// No description provided for @vehicleSupportQuirksHeading.
  ///
  /// In en, this message translates to:
  /// **'Known quirks on this vehicle'**
  String get vehicleSupportQuirksHeading;

  /// No description provided for @vehicleSupportNoQuirks.
  ///
  /// In en, this message translates to:
  /// **'No known quirks for this vehicle.'**
  String get vehicleSupportNoQuirks;

  /// No description provided for @vehicleSupportHuVendorRow.
  ///
  /// In en, this message translates to:
  /// **'Head unit'**
  String get vehicleSupportHuVendorRow;

  /// No description provided for @vehicleSupportVariantRow.
  ///
  /// In en, this message translates to:
  /// **'Vehicle'**
  String get vehicleSupportVariantRow;

  /// No description provided for @launcherBydLockedTitle.
  ///
  /// In en, this message translates to:
  /// **'Stock BYD locks default home'**
  String get launcherBydLockedTitle;

  /// No description provided for @launcherBydLockedBody.
  ///
  /// In en, this message translates to:
  /// **'BYD\'s vendor build prevents Android from changing the default home app to anything other than BYD MyCar. The home alias is enabled correctly — iLINK will appear in any home-picker that does open — but on stock BYD the system silently rejects the request. Workarounds: (1) install on a rooted BYD HU, (2) use a custom ROM, or (3) disable com.byd.mycar manually via adb (advanced).'**
  String get launcherBydLockedBody;
}

class _SDelegate extends LocalizationsDelegate<S> {
  const _SDelegate();

  @override
  Future<S> load(Locale locale) {
    return SynchronousFuture<S>(lookupS(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['ar', 'en', 'ru'].contains(locale.languageCode);

  @override
  bool shouldReload(_SDelegate old) => false;
}

S lookupS(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'ar':
      return SAr();
    case 'en':
      return SEn();
    case 'ru':
      return SRu();
  }

  throw FlutterError(
    'S.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
