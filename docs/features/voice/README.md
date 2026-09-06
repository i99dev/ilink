# Local voice commands

Manual voice is enabled in fresh settings, with English selected and wake-word listening off. The user must grant microphone permission. No login, credit balance, developer switch or internet service is required.

VoiceController requests permission and ensures model readiness before OnDeviceVoiceController starts capture. PlatformOnDeviceRecognizer bridges to Android's VoskGrammarRecognizer, which uses 16 kHz PCM from AudioRecord. VoskModelProvisioner prefers an existing model, an imported archive, then the bundled English archive before any explicitly enabled upstream download.

Final transcripts pass through the local grammar and intent matcher. Recognized commands use the real ToolRouter and CarClient.dispatch path, preserving integrity, vehicle-profile, rate and stationary checks. Unknown utterances do not trigger a remote assistant. Native recognition errors stop capture and display a failure; late results after cancellation are discarded.

Only English is bundled. Other languages need a compatible local import or enabled publisher download. The custom Arabic Moonshine fallback is retained only for compatible existing local files. It has no hosted provisioning service or new mirror-upload workflow.

See [model resources](../../offline-first/local-command-tables.md) and [verification](../../offline-first/final-verification.md). Host tests and desktop model decoding do not establish Android microphone performance, noisy-cabin accuracy or physical actuation.
