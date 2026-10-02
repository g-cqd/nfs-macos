import SwiftUI

/// The first-start checklist, shown until the player has signed in to the EA app.
struct NFS2015FirstRunView: View {
  let guide: NFS2015FirstRunGuide

  var body: some View {
    Section("First time on this Mac") {
      ForEach(Array(NFS2015FirstRunGuide.steps.enumerated()), id: \.offset) { index, step in
        VStack(alignment: .leading, spacing: 2) {
          Text("\(index + 1). \(step.title)").font(.callout.weight(.semibold))
          Text(step.detail).font(.caption).foregroundStyle(.secondary)
        }
      }
      Text(NFS2015FirstRunGuide.installerNote).font(.caption).foregroundStyle(.secondary)
      if guide.translocated {
        Text(NFS2015FirstRunGuide.translocationNotice).font(.caption)
      }
    }
  }
}
