import SwiftUI
import Combine
import LinkPresentation
import Defaults

struct AddWebsiteScreen: View {
	@Environment(\.dismiss) private var dismiss
	@State private var hostingWindow: NSWindow?
	@State private var isFetchingTitle = false
	@State private var isApplyConfirmationPresented = false
	@State private var originalWebsite: Website?
	@State private var urlString = ""
	@Namespace private var mainNamespace

	@State private var newWebsite = Website(
		id: UUID(),
		isCurrent: true,
		url: ".",
		usePrintStyles: false
	)

	private var isURLValid: Bool {
		URL.isValid(string: urlString)
			&& website.wrappedValue.url.isValid
	}

	private var hasChanges: Bool { website.wrappedValue != originalWebsite }

	private let isEditing: Bool

	// TODO: `@OptionalBinding` extension?
	private var existingWebsite: Binding<Website>?

	private var website: Binding<Website> { existingWebsite ?? $newWebsite }

	init(
		isEditing: Bool,
		website: Binding<Website>?
	) {
		self.isEditing = isEditing
		self.existingWebsite = website
		self._originalWebsite = .init(wrappedValue: website?.wrappedValue)

		if isEditing {
			self._urlString = .init(wrappedValue: website?.wrappedValue.url.absoluteString ?? "")
		}
	}

	var body: some View {
		VStack(alignment: .leading) {
			if SSApp.isFirstLaunch {
				firstLaunchView
			}
			VStack(alignment: .leading) {
				topView
				if isEditing {
					editingView
				}
			}
		}
			.frame(width: 500)
			.bindNativeWindow($hostingWindow)
			// Note: Current only works when a text field is focused. (macOS 11.3)
			.onExitCommand {
				guard isEditing, hasChanges else {
					dismiss()
					return
				}

				isApplyConfirmationPresented = true
			}
			.onSubmit {
				submit()
			}
			.confirmationDialog2(
				"Keep changes?",
				isPresented: $isApplyConfirmationPresented
			) {
				Button("Keep") {
					dismiss()
				}
				Button("Don't Keep", role: .destructive) {
					revert()
					dismiss()
				}
				Button("Cancel", role: .cancel) {}
			}
			.toolbar {
				// TODO: This can be simplified when `.toolbar` supports conditionals.
				ToolbarItem {
					if isEditing {
						Button("Revert") {
							revert()
						}
							.disabled(!hasChanges)
					}
				}
				ToolbarItem(placement: .cancellationAction) {
					if !isEditing {
						Button("Cancel") {
							dismiss()
						}
					}
				}
				ToolbarItem(placement: .confirmationAction) {
					Button(isEditing ? "Done" : "Add") {
						submit()
					}
						.disabled(!isURLValid)
				}
			}
	}

	private var firstLaunchView: some View {
		HStack {
			HStack(spacing: 3) {
				Text("You could, for example,")
				Button("show the time.") {
					urlString = "https://time.pablopunk.com/?seconds&fg=white&bg=transparent"
				}
					.buttonStyle(.link)
			}
			Spacer()
			Link("More ideas", destination: "https://github.com/sindresorhus/Plash/issues/1")
				.buttonStyle(.link)
		}
			.box()
	}

	private var topView: some View {
		VStack(alignment: .leading) {
			HStack {
				TextField(
					"twitter.com",
					// `removingNewlines` is a workaround for a SwiftUI bug where it doesn't respect the line limit when pasting in multiple lines. (macOS 12.0)
					// TODO: Report to Apple. Still an issue on macOS 13.
					text: $urlString.setMap(\.removingNewlines)
				)
					.textFieldStyle(.roundedBorder)
					.lineLimit(1)
					.prefersDefaultFocus(!isEditing, in: mainNamespace)
					.padding(.vertical)
					// This change listener is used to respond to URL changes from the outside, like the "Revert" button or the Shortcuts actions.
					.onChange(of: website.wrappedValue.url) {
						guard
							$0.absoluteString != "-",
							$0.absoluteString != urlString
						else {
							return
						}

						urlString = $0.absoluteString
					}
					.onChange(of: urlString) {
						guard let url = URL(humanString: $0) else {
							// Makes the “Revert” button work if the user clears the URL field.
							if urlString.trimmed.isEmpty {
								website.wrappedValue.url = "-"
							} else if let url = URL(string: $0) {
								website.wrappedValue.url = url
							}

							return
						}

						website.wrappedValue.url = url
							.normalized(
								// We need to allow typing `http://172.16.0.100:8080`.
								removeDefaultPort: false
							)
					}
					.onChangeDebounced(of: urlString, dueTime: 0.5) { _ in
						Task {
							await fetchTitle()
						}
					}
				Button("Local Website…") {
					Task {
						guard let url = await chooseLocalWebsite() else {
							return
						}

						urlString = url.absoluteString
					}
				}
			}
			TextField(
				"Title",
				// `removingNewlines` is a workaround for a SwiftUI bug where it doesn't respect the line limit when pasting in multiple lines. (macOS 12.0)
				text: website.title.setMap(\.removingNewlines)
			)
				.textFieldStyle(.roundedBorder)
				.lineLimit(1)
				.disabled(isFetchingTitle)
				.overlay(alignment: .trailing) {
					if isFetchingTitle {
						ProgressView()
							.controlSize(.small)
							.offset(x: -4)
					}
				}
		}
			.padding()
	}

	@ViewBuilder
	private var editingView: some View {
		Divider()
		VStack(alignment: .leading) {
			EnumPicker("Invert colors:", enumBinding: website.invertColors2) { element, _ in
				Text(element.title)
			}
				.fixedSize()
				.padding(.bottom, 4)
				.help("Creates a fake dark mode for websites without a native dark mode by inverting all the colors on the website.")
			Toggle("Use print styles", isOn: website.usePrintStyles)
				.help("Forces the website to use its print styles (“@media print”) if any. Some websites have a simpler presentation for printing, for example, Google Calendar.")
			// TODO: Put these inside a `DisclosureGroup` called `Advanced` when macOS 13 is out. It's too buggy on macOS 12.
			VStack(alignment: .leading) {
				HStack {
					Text("CSS:")
					Spacer()
					InfoPopoverButton("This lets you modify the website with CSS. You could, for example, change some colors or hide some unnecessary elements.")
						.controlSize(.small)
				}
				ScrollableTextView(
					text: website.css,
					font: .monospacedSystemFont(ofSize: 11, weight: .regular),
					isAutomaticQuoteSubstitutionEnabled: false,
					isAutomaticDashSubstitutionEnabled: false,
					isAutomaticTextReplacementEnabled: false,
					isAutomaticSpellingCorrectionEnabled: false
				)
					.frame(height: 70)
			}
				.padding(.top, 10)
			VStack(alignment: .leading) {
				HStack {
					Text("JavaScript:")
					Spacer()
					InfoPopoverButton("This lets you modify the website with JavaScript. Prefer using CSS instead whenever possible. You can use “await” at the top-level.")
						.controlSize(.small)
				}
				ScrollableTextView(
					text: website.javaScript,
					font: .monospacedSystemFont(ofSize: 11, weight: .regular),
					isAutomaticQuoteSubstitutionEnabled: false,
					isAutomaticDashSubstitutionEnabled: false,
					isAutomaticTextReplacementEnabled: false,
					isAutomaticSpellingCorrectionEnabled: false
				)
					.frame(height: 70)
			}
				.padding(.top, 10)
		}
			.padding()
	}

	private func submit() {
		if isEditing {
			dismiss()
		} else {
			add()
		}
	}

	private func revert() {
		guard let originalWebsite else {
			return
		}

		website.wrappedValue = originalWebsite
	}

	private func add() {
		WebsitesController.shared.add(website.wrappedValue)
		dismiss()

		SSApp.runOnce(identifier: "editWebsiteTip") {
			// TODO: Find a better way to inform the user about this.
			Task {
				await NSAlert.show(
					title: "Right-click a website in the list to edit it, toggle dark mode, add custom CSS/JavaScript, and more."
				)
			}
		}
	}

	@MainActor
	private func chooseLocalWebsite() async -> URL? {
//		guard let hostingWIndow else {
//			return nil
//		}

		let panel = NSOpenPanel()
		panel.canChooseFiles = false
		panel.canChooseDirectories = true
		panel.canCreateDirectories = false
		panel.title = "Choose Local Website"
		panel.message = "Choose a directory with a “index.html” file."
		panel.prompt = "Choose"

		// Ensure it's above the window when in "Browsing Mode".
		panel.level = .modalPanel

		let url = website.wrappedValue.url

		if
			isEditing,
			url.isFileURL
		{
			panel.directoryURL = url
		}

		// TODO: Make it a sheet instead when targeting macOS 13. On macOS 12.4, it doesn't work to open a sheet inside another sheet.
//		let result = await panel.beginSheet(hostingWIndow)
		let result = await panel.begin()

		guard
			result == .OK,
			let url = panel.url
		else {
			return nil
		}

		guard url.appendingPathComponent("index.html", isDirectory: false).exists else {
			await NSAlert.show(title: "Please choose a directory that contains a “index.html” file.")
			return await chooseLocalWebsite()
		}

		do {
			try SecurityScopedBookmarkManager.saveBookmark(for: url)
		} catch {
			await error.present()
			return nil
		}

		return url
	}

	@MainActor
	private func fetchTitle() async {
		// Ensure we don't erase a user's existing title.
		if
			isEditing,
			!website.title.wrappedValue.isEmpty
		{
			return
		}

		let url = website.wrappedValue.url

		guard url.isValid else {
			website.wrappedValue.title = ""
			return
		}

		withAnimation {
			isFetchingTitle = true
		}

		defer {
			withAnimation {
				isFetchingTitle = false
			}
		}

		let metadataProvider = LPMetadataProvider()
		metadataProvider.shouldFetchSubresources = false
		metadataProvider.timeout = 5

		guard
			let metadata = try? await metadataProvider.startFetchingMetadata(for: url),
			let title = metadata.title
		else {
			if !isEditing || website.wrappedValue.title.isEmpty {
				website.wrappedValue.title = ""
			}

			return
		}

		website.wrappedValue.title = title
	}
}

struct AddWebsiteScreen_Previews: PreviewProvider {
	static var previews: some View {
		AddWebsiteScreen(
			isEditing: false,
			website: nil
		)
	}
}
