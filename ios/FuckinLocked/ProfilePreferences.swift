import SwiftUI
import PhotosUI

struct AppPreferences: Codable, Equatable {
    var largerMessages = false
    var reduceAnimations = false
    var haptics = true
}

struct ProfilePreferencesView: View {
    @EnvironmentObject var vault: LocalVault
    @EnvironmentObject var gateway: Gateway
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var username = ""
    @State private var preferences = AppPreferences()
    @State private var photo: PhotosPickerItem?
    @State private var status = ""
    @State private var busy = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Name", text: $name).disabled(vault.deviceID.isEmpty)
                    TextField("Username", text: $username).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().disabled(vault.deviceID.isEmpty)
                    PhotosPicker(selection: $photo, matching: .images, preferredItemEncoding: .current) {
                        Text("Choose local avatar")
                    }
                    if vault.profileAvatar != nil {
                        Button("Remove local avatar") {
                            do { try vault.setAvatar(nil) } catch { status = "Couldn't save avatar" }
                        }
                    }
                    Text("This avatar is stored only on this iPhone. Your name and username are visible to approved members.").font(.footnote)
                }
                Section("Appearance and accessibility") {
                    Toggle("Larger message text", isOn: $preferences.largerMessages)
                    Toggle("Reduce animations further", isOn: $preferences.reduceAnimations)
                    Toggle("Haptic feedback", isOn: $preferences.haptics)
                    Text("iPhone Dynamic Type and Reduce Motion are always respected. These settings cannot change privacy protections.").font(.footnote)
                }
                if !status.isEmpty { Text(status) }
                Button("Save changes") {
                    busy = true
                    let generation = vault.chatGeneration
                    Task {
                        defer { busy = false }
                        do {
                            if !vault.deviceID.isEmpty {
                                try await gateway.login(deviceID: vault.deviceID)
                                let profile = try await gateway.updateProfile(name: name, username: username)
                                guard vault.isUnlocked, vault.chatGeneration == generation else { return }
                                try vault.setProfile(name: profile.name, username: profile.username,
                                                     userID: profile.user_id, deviceID: profile.device_id)
                            }
                            try vault.setPreferences(preferences)
                            dismiss()
                        } catch { status = "Couldn't save. Check the name, username and connection." }
                    }
                }.disabled(busy)
            }.navigationTitle("Profile and appearance")
                .toolbar { Button("Close") { dismiss() } }
                .task { name = vault.profileName; username = vault.username; preferences = vault.preferences }
                .onChange(of: photo) { _, item in
                    guard let item else { return }
                    let generation = vault.chatGeneration
                    Task {
                        defer { photo = nil }
                        do {
                            guard let bytes = try await item.loadTransferable(type: Data.self),
                                  vault.isUnlocked, vault.chatGeneration == generation else { return }
                            try vault.setAvatar(PrivateImage.importImage(bytes))
                            status = "Local avatar saved"
                        } catch { status = "Couldn't import this image" }
                    }
                }
        }.onDisappear { name = ""; username = ""; photo = nil }
    }
}
