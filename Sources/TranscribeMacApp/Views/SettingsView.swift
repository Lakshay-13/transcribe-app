import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: TranscriptionViewModel

    var body: some View {
        Form {
            Section("Transcription Mode") {
                Picker("Mode", selection: $viewModel.selectedMode) {
                    ForEach(TranscriptionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            if viewModel.selectedMode == .local {
                Section("Local") {
                    Text(viewModel.ramRecommendationText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Picker("Model Profile", selection: $viewModel.selectedProfile) {
                        ForEach(WhisperProfile.allCases) { profile in
                            Text("\(profile.displayName) (\(profile.defaultModelID))").tag(profile)
                        }
                    }
                    .pickerStyle(.menu)

                    TextField("Custom model override", text: $viewModel.customLocalModel)
                        .textFieldStyle(.roundedBorder)

                    Divider()

                    Toggle("Streaming Transcript", isOn: $viewModel.enableStreamingTranscript)
                    TextField("Section time in seconds", text: $viewModel.localChunkDurationSeconds)
                        .textFieldStyle(.roundedBorder)
                    Text("Higher value generally reduces section overhead for longer videos.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let chunkValidation = viewModel.chunkDurationValidationMessage {
                        Text(chunkValidation)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Install Diarization Models")
                            .font(.subheadline.weight(.semibold))
                        Text(viewModel.diarizationSetupStateText)
                            .font(.caption)
                            .foregroundStyle(viewModel.diarizationSetupStatus == .failed ? Color.red : Color.secondary)

                        SecureField("Hugging Face token", text: $viewModel.diarizationSetupToken)
                            .textFieldStyle(.roundedBorder)

                        Button(viewModel.isDiarizationSetupRunning ? "Installing..." : "Install Diarization Models") {
                            viewModel.installDiarizationModels()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isDiarizationSetupRunning || viewModel.diarizationSetupToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Text("Installs/validates whisperx diarization prerequisites and verifies token access for pyannote models.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Toggle("Speaker Separation (Experimental)", isOn: $viewModel.enableSpeakerDiarization)
                        .disabled(!viewModel.isDiarizationReady || viewModel.isDiarizationSetupRunning)

                    if !viewModel.isDiarizationReady {
                        Text("Run setup first to enable speaker separation.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if viewModel.enableSpeakerDiarization {
                        TextField("Expected speakers (optional)", text: $viewModel.expectedSpeakerCount)
                            .textFieldStyle(.roundedBorder)

                        Text("Uses installed diarization models and your verified token.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section("API") {
                    SecureField("OpenAI API key", text: $viewModel.apiKey)
                        .textFieldStyle(.roundedBorder)
                    TextField("API model", text: $viewModel.apiModel)
                        .textFieldStyle(.roundedBorder)
                    TextField("API base URL override (optional)", text: $viewModel.apiBaseURLOverride)
                        .textFieldStyle(.roundedBorder)
                    Text("Use a base URL (for example, http://127.0.0.1:11002) or a full /audio/transcriptions endpoint.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Language & Output") {
                Picker("Language", selection: $viewModel.selectedLanguage) {
                    ForEach(WhisperLanguage.common) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.menu)

                Picker("Output", selection: $viewModel.outputStyle) {
                    ForEach(OutputStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .padding(14)
        .frame(width: 560, height: 420)
    }
}
