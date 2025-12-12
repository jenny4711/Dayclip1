//
//  CalendarViews.swift
//  Dayclip1
//
//  Created by Ji y LEE on 11/7/25.
//

import SwiftUI

// MARK: - Calendar Month Page

struct CalendarMonthPage: View {
    let month: CalendarMonth
    let viewportHeight: CGFloat
    let viewportWidth: CGFloat
    let clipCount: Int
    let savingDay: Date?
    let onDaySelected: (CalendarDay) -> Void

    private let horizontalPadding: CGFloat = 20
    private let cellSpacing: CGFloat = 6
//test
    var body: some View {
        let availableWidth = viewportWidth - (horizontalPadding * 2)
        let minimumCellWidth: CGFloat = 45
        let computedCellWidth = (availableWidth - (cellSpacing * 6)) / 7
        let cellWidth = max(computedCellWidth, minimumCellWidth)
        let cellHeight: CGFloat = 81
        let gridHeight = month.gridHeight(cellHeight: cellHeight, rowSpacing: cellSpacing)

        let columns: [GridItem] = Array(repeating: GridItem(.fixed(cellWidth), spacing: cellSpacing), count: 7)

        let calendar = Calendar.current
        
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(month.title) \(month.yearTitle)")
                        .font(.system(size: 14).weight(.medium))
                        .foregroundStyle(.white)
                }
              
                Spacer()
            }
            .padding(.horizontal, horizontalPadding)

            VStack(spacing: 12) {
                HStack(spacing: cellSpacing) {
                    ForEach(Weekday.allCases, id: \.self) { weekday in
                        Text(weekday.displaySymbol)
                            .font(.system(size: 10,weight: .medium))
                            .foregroundStyle(.gray)
                            .frame(maxWidth: .infinity)
                    }
                }
               

                LazyVGrid(columns: columns, spacing: cellSpacing) {
                    ForEach(month.days) { day in
                        let isSaving = savingDay.map {
                            day.kind == .current && calendar.isDate(day.date, inSameDayAs: $0)
                        } ?? false
                        DayCellView(
                            day: day,
                            size: CGSize(width: cellWidth, height: cellHeight),
                            isSaving: isSaving,
                            onTap: onDaySelected
                        )
                    }
                }
                .frame(height: gridHeight)
            }
            .padding(.horizontal, horizontalPadding)

            // Spacer(minLength: 0)  // Removed to use minimum height only
        }
        .frame(minHeight: 0)  // Use minimum height instead of fixed viewportHeight
//        .background(.red)
        
    }
}

// MARK: - Day Cell View

struct DayCellView: View {
    let day: CalendarDay
    let size: CGSize
    let isSaving: Bool
    let onTap: (CalendarDay) -> Void

    private let cornerRadius: CGFloat = 8

    var body: some View {
        Group {
            if day.isSelectable {
                Button {
                    onTap(day)
                } label: {
                    cellBody
                }
                .buttonStyle(.plain)
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .disabled(isSaving)
            } else {
                cellBody
            }
        }
    }

    private var cellBody: some View {
        ZStack {
            // Background color - only show if no thumbnail
            if day.thumbnail == nil {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(day.backgroundColor)
            }

            // Thumbnail - fill entire cell if present (현재 달 날짜에만 표시)
            if let thumbnail = day.thumbnail, day.kind == .current {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
            }

            // Date number overlay - centered
            Text(day.displayText)
                .font(.system(size: 12).weight(.medium))
                .foregroundStyle(day.thumbnail != nil ? .white : day.textColor)
                .shadow(color: Color.black.opacity(day.thumbnail != nil ? 0.5 : 0.35), radius: 1, x: 0, y: 0)
            
            if isSaving {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.black.opacity(0.45))
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .opacity(day.opacity)
    }
}

// MARK: - Player Action Button Style

struct PlayerActionButtonStyle: ButtonStyle {
    var tint: Color = Color.white.opacity(0.2)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

