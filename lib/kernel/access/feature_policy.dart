/// Local application features; all are available without an account.
enum Feature {
  radio,
  tv,
  voiceAssistant,
  remoteHelp,
  profileDetails,
  developerSettings,
  voiceOfflineMode,
  voicePersonaMemory,
  voiceMultiDeviceSync,
  voicePreferences,
}

enum LockedRenderMode { replace, disable }

class FeaturePolicy {
  const FeaturePolicy();
}

const Map<Feature, FeaturePolicy> featurePolicy = {
  Feature.radio: FeaturePolicy(),
  Feature.tv: FeaturePolicy(),
  Feature.voiceAssistant: FeaturePolicy(),
  Feature.remoteHelp: FeaturePolicy(),
  Feature.profileDetails: FeaturePolicy(),
  Feature.developerSettings: FeaturePolicy(),
  Feature.voiceOfflineMode: FeaturePolicy(),
  Feature.voicePersonaMemory: FeaturePolicy(),
  Feature.voiceMultiDeviceSync: FeaturePolicy(),
  Feature.voicePreferences: FeaturePolicy(),
};
