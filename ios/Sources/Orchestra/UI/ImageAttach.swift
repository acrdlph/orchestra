import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// **One attachment control, used by both composers.**
///
/// The chat composer and the mission composer are laid out nothing alike — one
/// is a bottom bar with a one-to-five-line field, the other a 180 pt editor in a
/// scroll view — but the *behaviour* of attaching a picture is identical, and
/// two implementations of it would be two places for the demo refusal, the size
/// precheck and the insert rule to drift apart. So the behaviour is here, in two
/// views that either composer can place where its own layout wants them:
///
/// * `AttachButton` — the paperclip. Owns the sources, the upload, and the write
///   into the draft.
/// * `AttachmentStrip` — the tiles, the progress and the failure sentence. Owns
///   nothing; everything it draws is derived from the draft text.
///
/// **The draft text is the only model.** There is no attachment object anywhere
/// in this file: `AttachButton` inserts a path into a String and `AttachmentStrip`
/// reads paths back out of that same String (`UploadPath.paths`). Deleting the
/// path deletes the attachment, backgrounding persists it because
/// `DraftStore` already persists text, and the send path types text. Three
/// things that would otherwise each need their own copy.
struct AttachButton: View {
    let uploads: UploadStore
    let isDemo: Bool
    @Binding var text: String
    /// The caret, when the composer has one to give. `nil` appends.
    @Binding var selection: TextSelection?

    @State private var choosingSource = false
    @State private var photo: PhotosPickerItem?
    @State private var browsingFiles = false

    var body: some View {
        Button {
            // **Demo refuses at the tap, before a picker opens.** The control
            // stays visible — a reviewer is here to see that the app can attach
            // a picture — and it answers in the server's own voice rather than
            // letting somebody choose a photo and only then be told (`DemoCopy`).
            if isDemo {
                uploads.refuse(DemoCopy.refusal)
            } else {
                uploads.clearFailure()
                choosingSource = true
            }
        } label: {
            Image(systemName: "paperclip")
                .font(OrcFont.button)
                .foregroundStyle(uploads.isBusy ? Palette.textDisabled : Palette.statusFree)
                .frame(width: 44, height: 44)
                .background(Palette.raised)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .stroke(Palette.control, lineWidth: 1))
        }
        .disabled(uploads.isBusy)
        .accessibilityLabel("attach an image")
        .accessibilityHint("Uploads it to the Mac and puts its path in the message")
        // A dialog rather than a `Menu`, for the reason the option pickers were
        // rebuilt: a menu is laid out into the space left around its anchor, and
        // this anchor sits directly above the keyboard.
        .confirmationDialog("Attach an image", isPresented: $choosingSource,
                            titleVisibility: .visible) {
            Button("Photo Library") { choosingSource = false; photoPickerUp = true }
            Button("Files") { choosingSource = false; browsingFiles = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It is uploaded to your Mac and its path goes into the message — "
                 + "which is how an agent reads a picture.")
        }
        .photosPicker(isPresented: $photoPickerUp, selection: $photo, matching: .images,
                      photoLibrary: .shared())
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task { await take(item) }
        }
        // The system document browser. Cheap — one modifier — and it is the only
        // way to reach a file that is not in the photo library: a screenshot
        // saved to iCloud Drive, an image AirDropped into Files.
        .fileImporter(isPresented: $browsingFiles,
                      allowedContentTypes: [.png, .jpeg, .gif, .webP, .heic, .heif, .image]) { result in
            switch result {
            case .success(let url):
                Task { await take(url) }
            case .failure(let error):
                uploads.refuse("that file could not be opened: \(error.localizedDescription)")
            }
        }
        #if DEBUG
        // `ORC_UPLOAD=<path to an image>` — the fourth `#if DEBUG` seam, and it
        // exists for exactly `ORC_SEND`'s reason.
        //
        // **A simulator has no photo library worth picking from and cannot be
        // tapped from a script**, and the gate for this feature is *a real image
        // reached a real Mac and its real path came back*. So the seam reads a
        // file off disk and hands it to the SAME `UploadStore.attach` and the
        // SAME `insert` the picker's callback uses — the transcode, the size
        // precheck, the POST, the strip and the draft write are all the shipping
        // code. It is a way to press the button, not a second way to upload.
        //
        // It fires once per mounted composer. Two composers mounted at once
        // would upload the same bytes twice, which is free: the server names the
        // file by its content digest, so the second request returns the same
        // path and writes nothing (`uploads.py` rule 2).
        .task {
            guard !seamFired,
                  let value = ProcessInfo.processInfo.environment["ORC_UPLOAD"],
                  !value.isEmpty else { return }
            seamFired = true
            // Two words instead of a path press the two things a *tap* opens and
            // a script otherwise cannot — the source dialog and the system photo
            // sheet — through exactly the state the button's action sets.
            switch value {
            case "picker", "photos":
                // A presentation asked for from the `.task` of a view that is
                // still being built is swallowed — and on a locked launch the
                // gate rebuilds this whole subtree once more. One beat is
                // enough, and it costs a shipping path nothing: this arm is
                // reached only by the two seam words.
                try? await Task.sleep(for: .seconds(1))
                if isDemo {
                    uploads.refuse(DemoCopy.refusal)
                } else if value == "picker" {
                    choosingSource = true
                } else {
                    photoPickerUp = true
                }
                return
            default:
                break
            }
            guard let raw = FileManager.default.contents(atPath: value) else {
                uploads.refuse("ORC_UPLOAD: nothing readable at \(value)")
                return
            }
            await upload(raw, name: (value as NSString).lastPathComponent)
        }
        #endif
    }

    /// Held separately from `choosingSource` because a `.photosPicker` presented
    /// from inside a confirmation dialog's action needs the dialog gone first.
    @State private var photoPickerUp = false

    #if DEBUG
    @State private var seamFired = false
    #endif

    // MARK: - the one flow

    private func take(_ item: PhotosPickerItem) async {
        do {
            // `Data.self`, not `Image.self`: the ORIGINAL file's bytes, which for
            // an iOS screenshot is the untouched PNG. Asking for an `Image` would
            // hand back a decoded, re-encoded copy and throw away the exact thing
            // this feature is for.
            guard let raw = try await item.loadTransferable(type: Data.self) else {
                uploads.refuse("that item had no image data on this phone — if it "
                               + "is in iCloud Photos, open it once in Photos and "
                               + "try again.")
                return
            }
            await upload(raw, name: item.itemIdentifier)
        } catch {
            uploads.refuse("that photo could not be read: \(error.localizedDescription)")
        }
    }

    private func take(_ url: URL) async {
        // A file the importer handed us lives outside the app's container, so
        // the read has to be inside a security scope. `defer` and not a manual
        // balance: a throw between the two would leak the scope for the life of
        // the process.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let raw = try Data(contentsOf: url)
            await upload(raw, name: url.lastPathComponent)
        } catch {
            uploads.refuse("that file could not be read: \(error.localizedDescription)")
        }
    }

    /// Upload, then write the path into the draft **at the caret if there is
    /// one**.
    ///
    /// Nothing here can lose what the user was writing: the insert is a pure
    /// function of the text as it stands at this instant (`DraftAttachment`), and
    /// a failure returns `nil` and touches the draft not at all.
    private func upload(_ raw: Data, name: String?) async {
        guard let path = await uploads.attach(raw, name: name, isDemo: isDemo) else { return }
        insert(path)
    }

    /// The write. Separated so the `#if DEBUG` seam can press exactly this.
    func insert(_ path: String) {
        let caret = Self.caretOffset(of: selection, in: text)
        let result = DraftAttachment.inserting(path, into: text, at: caret)
        text = result.text
        // Put the caret back past what was inserted. Best effort by nature —
        // assigning a bound String is what moves a caret to the end in the first
        // place — but when it takes, the next keystroke continues the sentence
        // instead of landing on the extension.
        if let index = Self.index(at: result.caret, in: result.text) {
            selection = TextSelection(insertionPoint: index)
        }
    }

    /// The caret as a Character offset, or nil for "no single insertion point" —
    /// an unfocused field, or a range selection, both of which mean append.
    ///
    /// The measuring is `DraftAttachment.caret`'s, not this file's, because the
    /// naive one **crashed the app** on the first real upload and a rule that
    /// crashed once belongs where a test can reach it.
    static func caretOffset(of selection: TextSelection?, in text: String) -> Int? {
        guard let selection, case .selection(let range) = selection.indices,
              range.isEmpty else { return nil }
        return DraftAttachment.caret(at: range.lowerBound, in: text)
    }

    static func index(at offset: Int, in text: String) -> String.Index? {
        guard offset >= 0, offset <= text.count else { return nil }
        return text.index(text.startIndex, offsetBy: offset)
    }
}

/// The attachments on this draft — **read out of the draft**, plus whatever is
/// happening to an upload right now.
///
/// Every tile here exists because a path is in the text. There is no list to
/// keep in step: a user who selects the path and deletes it has removed the
/// attachment, and this strip redraws with one fewer tile on the next keystroke,
/// because it never held anything of its own.
struct AttachmentStrip: View {
    let uploads: UploadStore
    @Binding var text: String

    private var paths: [String] { UploadPath.paths(in: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if !paths.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: Space.sm) {
                        ForEach(paths, id: \.self) { path in
                            tile(path)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(height: 68)
            }
            progress
            failure
        }
    }

    @ViewBuilder
    private func tile(_ path: String) -> some View {
        let name = (path as NSString).lastPathComponent
        ZStack(alignment: .topTrailing) {
            Group {
                if let data = uploads.thumbnail(for: path), let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    // **No download is invented for this.** The picture is on the
                    // Mac and this phone is not the one that put it there (or was
                    // relaunched since). The tile says what is true: the file
                    // exists, under this name.
                    VStack(spacing: Space.xxs) {
                        Image(systemName: "photo")
                            .font(OrcFont.meta)
                            .foregroundStyle(Palette.textTertiary)
                        Text(verbatim: String(name.prefix(6)))
                            .font(OrcFont.meta)
                            .foregroundStyle(Palette.textDisabled)
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: 56, height: 56)
            .background(Palette.sunken)
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .stroke(Palette.hairline, lineWidth: 1))

            Button {
                // The only removal there is: take the path out of the text.
                text = DraftAttachment.removing(path, from: text)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Palette.textPrimary, Palette.canvas)
                    .padding(Space.xs)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("remove \(name) from this message")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("attached image \(name)")
    }

    @ViewBuilder
    private var progress: some View {
        switch uploads.phase {
        case .preparing:
            // Named honestly. This is the phone's own work — decode, downscale,
            // re-encode — and calling it "uploading" would be the first small lie
            // in a screen whose whole job is receipts.
            HStack(spacing: Space.sm) {
                ProgressView().controlSize(.small).tint(Palette.textTertiary)
                Text("shrinking it for the upload…")
                    .font(OrcFont.meta)
                    .foregroundStyle(Palette.textTertiary)
            }
        case .sending(let fraction):
            HStack(spacing: Space.sm) {
                ProgressView(value: fraction)
                    .tint(Palette.statusFree)
                    .frame(maxWidth: 140)
                Text(verbatim: "uploading \(Int(fraction * 100))%")
                    .font(OrcFont.meta)
                    .foregroundStyle(Palette.textTertiary)
            }
        case .idle, .failed:
            EmptyView()
        }
    }

    @ViewBuilder
    private var failure: some View {
        if let why = uploads.failure {
            HStack(alignment: .top, spacing: Space.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(OrcFont.meta)
                    .foregroundStyle(Palette.statusNeeds)
                // **The server's own sentence, verbatim.** Every refusal this
                // route writes is something the person holding the phone has to
                // fix, and the remedy is inside the words.
                Text(why)
                    .font(OrcFont.meta)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Button("dismiss") { uploads.clearFailure() }
                    .font(OrcFont.meta)
                    .foregroundStyle(Palette.statusFree)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
