import Foundation

struct GarageAllocation {
  let row: Int
  let part: Int
  let career: Int

  init(data: Data) throws(LauncherError) {
    guard data.count == CareerSave.size else { throw .operation("Invalid save size.") }
    var rows: [Int] = []
    var usedParts: Set<Int> = []
    var usedCareers: Set<Int> = []
    for row in 0..<119 {
      let offset = 0x6219 + row * 20
      let empty = data[offset..<offset + 4].allSatisfy { $0 == 255 }
      if !empty {
        usedParts.insert(Int(data[offset + 16]))
        usedCareers.insert(Int(data[offset + 17]))
      } else {
        // Empty rows with My Cars visual references belong to a sidecar and stay reserved.
        if data[offset + 12] == 4
          && data[offset + 4..<offset + 12].contains(where: { $0 != 0 && $0 != 255 })
        {
          usedParts.insert(Int(data[offset + 16]))
        } else {
          rows.append(row)
        }
      }
    }
    let parts = (31..<75).filter { slot in
      let offset = 0x9ccd + (slot - 31) * 408 + 404
      return !usedParts.contains(slot) && data[offset..<offset + 4] == Data([255, 205, 205, 205])
    }
    let careers = (0..<25).filter { !usedCareers.contains($0) && data[0xe2ed + $0 * 56] == 255 }
    guard let row = rows.first, let part = parts.first, let career = careers.first else {
      throw .operation("No independent car, parts, or career record is available.")
    }
    self.row = row
    self.part = part
    self.career = career
  }
}
