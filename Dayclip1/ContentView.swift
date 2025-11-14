//
//  ContentView.swift
//  Dayclip1
//
//  Created by Ji y LEE on 11/7/25.
//

import SwiftUI
import Combine
import PhotosUI
import AVFoundation
import AVKit
import UniformTypeIdentifiers
import UIKit
import QuartzCore
import CoreMedia
 // MARK: - contentView
struct ContentView: View {
    @StateObject private var viewModel = CalendarViewModel()
    @State private var pendingDaySelection: CalendarDay?
    @State private var isShowingPicker = false
    @State private var selectedPickerItems: [PhotosPickerItem] = []
    @State private var showReplaceAlert = false
    @State private var isSavingClip = false
    @State private var errorMessage: String?
    @State private var editorDraft: EditorDraft?
    @State private var monthlyPlaybackSession: MonthlyPlaybackSession?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 40) {
                        ForEach(viewModel.months) { month in
                            CalendarMonthPage(
                                month: month,
                                viewportHeight: geometry.size.height,
                                viewportWidth: geometry.size.width,
                                clipCount: viewModel.clipCount(for: month),
                                onDaySelected: handleDaySelection
                            )
                                .frame(width: geometry.size.width)
                        }
                    }
                    .padding(.vertical, 32)
                    .padding(.bottom, 100)
                }
                
                VStack {
                    Spacer()
                    Button {
                        startTimelinePlayback()
                    } label: {
                        Label("전체 타임라인 재생", systemImage: "play.circle.fill")
                            .font(.headline.weight(.semibold))
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(PlayerActionButtonStyle(tint: Color.white.opacity(0.25)))
                    .disabled(viewModel.allClips().isEmpty)
                    .opacity(viewModel.allClips().isEmpty ? 0.4 : 1.0)
                    .padding(.bottom, 40)
                }
            }
            .photosPicker(
                isPresented: $isShowingPicker,
                selection: $selectedPickerItems,
                maxSelectionCount: 1,
                matching: .videos,
                photoLibrary: .shared()
            )
            .onChange(of: selectedPickerItems) { _, newItems in
                Task { await handlePickerItems(newItems) }
            }
            .onChange(of: isShowingPicker) { _, isPresented in
                if !isPresented && selectedPickerItems.isEmpty {
                    resetPendingSelection()
                }
            }
            .alert(
                "기존 영상을 교체하시겠습니까?",
                isPresented: $showReplaceAlert,
                presenting: pendingDaySelection
            ) { _ in
                Button("교체", role: .destructive) {
                    presentPickerForPendingDay()
                }
                Button("취소", role: .cancel) {
                    pendingDaySelection = nil
                }
            } message: { _ in
                Text("선택한 날짜의 기존 영상을 교체합니다.")
            }
            .background(Color.black.ignoresSafeArea())
            .overlay {
                if isSavingClip {
                    ZStack {
                        Color.black.opacity(0.35).ignoresSafeArea()
                        ProgressView("영상을 저장 중입니다…")
                            .padding(20)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }
        }
        .alert("문제가 발생했어요", isPresented: Binding(get: {
            errorMessage != nil
        }, set: { newValue in
            if !newValue {
                errorMessage = nil
            }
        }), actions: {
            Button("확인", role: .cancel) {
                errorMessage = nil
            }
        }, message: {
            Text(errorMessage ?? "")
        })
        .fullScreenCover(item: $editorDraft) { draft in
            MultiClipEditorView(
                draft: draft,
                onCancel: {
                    editorDraft = nil
                    resetPendingSelection()
                },
                onComplete: { composition in
                    editorDraft = nil
                    Task {
                        await handleEditorCompletion(composition)
                    }
                }
            )
        }
        .fullScreenCover(item: $monthlyPlaybackSession) { session in
            MonthlyPlaybackView(session: session) {
                monthlyPlaybackSession = nil
            }
        }
        .preferredColorScheme(.dark)
       
        .task {
            await viewModel.loadPersistedClips()
        }
    }

    private func handleDaySelection(_ day: CalendarDay) {
        guard day.isSelectable else { return }
        pendingDaySelection = day

        if day.hasClip {
            presentEditorForExistingDay(day)
        } else {
            presentPickerForPendingDay()
        }
    }
    
    private func startTimelinePlayback() {
        let clips = viewModel.allClips()
        guard !clips.isEmpty else {
            errorMessage = "저장된 영상이 없습니다."
            return
        }
        
        let firstDate = clips.first?.date ?? Date()
        monthlyPlaybackSession = MonthlyPlaybackSession(monthDate: firstDate, clips: clips)
    }
    
    private func presentEditorForExistingDay(_ day: CalendarDay) {
        guard let clip = viewModel.clip(for: day.date) else {
            presentPickerForPendingDay()
            return
        }
        presentEditorForExistingClip(clip)
    }

    private func presentPickerForPendingDay() {
        guard pendingDaySelection != nil else { return }
        showReplaceAlert = false
        selectedPickerItems = []
        isShowingPicker = true
    }

    private func resetPendingSelection() {
        pendingDaySelection = nil
        selectedPickerItems = []
        isShowingPicker = false
        showReplaceAlert = false
    }

    private func handlePickerItems(_ items: [PhotosPickerItem]) async {
        guard let item = items.first else { return }

        let day = await MainActor.run { pendingDaySelection }

        guard let day else {
            await MainActor.run { selectedPickerItems = [] }
            return
        }

        VideoStorageManager.shared.clearEditingSession(for: day.date)

        await MainActor.run {
            editorDraft = EditorDraft(date: day.date, sources: [.picker(item)])
            isShowingPicker = false
            selectedPickerItems = []
        }
    }

    private func deleteClip(_ clip: DayClip) async {
        await MainActor.run {
            isSavingClip = true
        }

        do {
            try VideoStorageManager.shared.removeClip(clip)
            VideoStorageManager.shared.clearEditingSession(for: clip.date)
            try await ClipStore.shared.deleteClip(for: clip.date)
            await MainActor.run {
                viewModel.removeClip(for: clip.date)
                resetPendingSelection()
            }
        } catch {
            await MainActor.run {
                errorMessage = "영상을 삭제하지 못했습니다.\n\(error.localizedDescription)"
            }
        }

        await MainActor.run {
            isSavingClip = false
        }
    }

    private func handleEditorCompletion(_ composition: EditorCompositionDraft) async {
        let day = await MainActor.run { pendingDaySelection }

        guard let day else {
            await MainActor.run {
                errorMessage = "편집을 저장할 수 있는 날짜를 찾지 못했습니다."
                resetPendingSelection()
            }
            return
        }

        await MainActor.run {
            isSavingClip = true
        }

        do {
            let clip = try await VideoStorageManager.shared.exportComposition(
                draft: composition,
                date: day.date
            )

            try await ClipStore.shared.upsert(clip.metadata)

            await MainActor.run {
                viewModel.setClip(clip)
                resetPendingSelection()
            }
        } catch {
            await MainActor.run {
                errorMessage = "편집본을 저장하지 못했습니다.\n\(error.localizedDescription)"
                resetPendingSelection()
            }
        }

        await MainActor.run {
            isSavingClip = false
        }
    }

    private func presentEditorForExistingClip(_ clip: DayClip) {
        let sources = VideoStorageManager.shared.loadEditingSources(for: clip.date)
        guard !sources.isEmpty else {
            errorMessage = "편집 세션을 불러올 수 없습니다. 새 영상을 선택해 주세요."
            return
        }

        let day = viewModel.day(for: clip.date)
        let today = Date()
        let calendar = Calendar.current
        let calendarDay = day ?? CalendarDay(
            date: clip.date,
            kind: .current,
            isToday: calendar.isDate(clip.date, inSameDayAs: today),
            isFuture: clip.date > today,
            hasClip: true,
            thumbnail: clip.thumbnail
        )

        pendingDaySelection = calendarDay
        editorDraft = EditorDraft(date: clip.date, sources: sources.map { .file($0) })
    }
}

#Preview {
    ContentView()
}
