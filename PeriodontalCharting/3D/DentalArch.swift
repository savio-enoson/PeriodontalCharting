//
//  DentalArch.swift
//  PeriodontalCharting
//
//  Anatomy-side counterpart to the 2-D chart's quadrant grouping. FDI order
//  here is identical to the quadrant arrays ChartDashboard builds its columns
//  from (q1+q2 for the maxilla, q4+q3 for the mandible), so index order lines
//  up between the two views: a tooth's neighbour in this list is also its
//  visual neighbour in the chart column, and — crucially for the anatomy
//  generator — its neighbour in `AspectData` site index (0 = toward the
//  previous tooth in this list, 2 = toward the next).
//

import Foundation

enum DentalArch: CaseIterable {
    case maxilla   // upper
    case mandible  // lower

    /// FDI tooth numbers in the same left-to-right order the 2-D chart uses.
    var fdiOrder: [Int] {
        switch self {
        case .maxilla:  return [18, 17, 16, 15, 14, 13, 12, 11, 21, 22, 23, 24, 25, 26, 27, 28]
        case .mandible: return [48, 47, 46, 45, 44, 43, 42, 41, 31, 32, 33, 34, 35, 36, 37, 38]
        }
    }

    static func arch(ofFDI fdi: Int) -> DentalArch {
        let q = fdi / 10
        return (q == 1 || q == 2) ? .maxilla : .mandible
    }
}
