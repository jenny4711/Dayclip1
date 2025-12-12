//
//  ContentView.swift
//  Dayclip1
//
//  Created by Ji y LEE on 11/7/25.
//ㄷㄷ

import SwiftUI
import PhotosUI
 // MARK: - contentView
struct ContentView: View {
    @StateObject private var viewModel = CalendarViewModel()
    @State private var pendingDaySelection: CalendarDay?
    @State private var isShowingPicker = false
    @State private var selectedPickerItems: [PhotosPickerItem] = []
    @State private var showReplaceAlert = false
    @State private var savingDay: Date?
    @State private var errorMessage: String?
    @State private var editorDraft: EditorDraft?
    @State private var monthlyPlaybackSession: MonthlyPlaybackSession?


    
    var body: some View {
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    // 달력 스크롤
                    calendarScrollView(geometry: geometry)

                    // 플레이 버튼
                    playButton
                        // 화면 맨 아래 ↔ 버튼 아래 = 24
                        .padding(.bottom, 0)
                }
                .background(Color.black.ignoresSafeArea())
            }
            // MARK: - 사진/비디오 선택
            .photosPicker(
                isPresented: $isShowingPicker,
                selection: $selectedPickerItems,
                maxSelectionCount: 1,
                matching: .any(of: [.videos, .images]),
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

            // MARK: - 교체 알림
            .alert(
                "Replace existing video?",
                isPresented: $showReplaceAlert,
                presenting: pendingDaySelection
            ) { _ in
                Button("Replace", role: .destructive) {
                    presentPickerForPendingDay()
                }
                Button("Cancel", role: .cancel) {
                    pendingDaySelection = nil
                }
            } message: { _ in
                Text("This will replace the existing video for the selected date.")
            }

            // MARK: - 에러 알림
            .alert(
                "An error occurred",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { newValue in
                        if !newValue { errorMessage = nil }
                    }
                )
            ) {
                Button("OK", role: .cancel) {
                    errorMessage = nil
                }
            } message: {
                Text(errorMessage ?? "")
            }

            // MARK: - 에디터 / 월별 재생
            .fullScreenCover(item: $editorDraft) { draft in
                MultiClipEditorView(
                    draft: draft,
                    onCancel: {
                        editorDraft = nil
                        resetPendingSelection()
                    },
                    onComplete: { composition in
                        let savingDate = draft.date
                        savingDay = savingDate
                        editorDraft = nil
                        Task.detached(priority: .userInitiated) {
                            await handleEditorCompletion(for: savingDate, composition: composition)
                        }
                    },
                    onDelete: {
                        editorDraft = nil
                        Task {
                            await deleteClipForDate(draft.date)
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
    
    
    @ViewBuilder
       private func calendarScrollView(geometry: GeometryProxy) -> some View {
           ScrollViewReader { proxy in
               ScrollView(.vertical, showsIndicators: false) {
                   LazyVStack(spacing: 24) {
                       ForEach(viewModel.months) { month in
                           CalendarMonthPage(
                               month: month,
                               viewportHeight: geometry.size.height,
                               viewportWidth: geometry.size.width,
                               clipCount: viewModel.clipCount(for: month),
                               savingDay: savingDay,
                               onDaySelected: handleDaySelection
                           )
                           .frame(width: geometry.size.width)
                           .id(month.id)
                       }
                   }
                   // 위 여백
                   .padding(.top, 32)
                   // 🔴 중요한 부분:
                   // 버튼 높이(42) + 달력↔버튼 위 간격(24) + 버튼↔화면 밑 간격(24) = 90
                   .padding(.bottom, 65)
                 /* .background(Color.yellow)*/ // 디버그용, 나중에 빼셔도 돼요
               }
               .background(Color.black.ignoresSafeArea())
               .onAppear {
                   scrollToCurrentMonth(proxy: proxy, animated: false)
               }
               .onChange(of: viewModel.months) { _, _ in
                   scrollToCurrentMonth(proxy: proxy, animated: false)
               }
           }
       }
    
    private var playButton: some View {
           Button {
               startTimelinePlayback()
           } label: {
               HStack(spacing: 8) {
                   Image(systemName: "play.circle")
                       .font(.system(size: 16, weight: .medium))
                   Text("Play")
                       .font(.system(size: 14, weight: .medium))
               }
               .foregroundStyle(.white)
               .frame(width: 82, height: 42) // 버튼 높이 42 기준
               .padding(.vertical, 2)
               .background(
                   Capsule()
                       .glassEffect()
               )
           }
           .buttonStyle(.plain)
           .glassEffect(.clear)
           .disabled(viewModel.allClips().isEmpty)
           .opacity(viewModel.allClips().isEmpty ? 0.0 : 1.0)
       }
    
    
    
    private func scrollToCurrentMonth(proxy: ScrollViewProxy, animated: Bool = false) {
        let today = Date()
        let calendar = Calendar.current
        
        // 현재 월과 일치하는 첫 번째 월 찾기
        if let currentMonth = viewModel.months.first(where: { month in
            calendar.isDate(month.date, equalTo: today, toGranularity: .month)
        }) {
            if animated {
                withAnimation {
                    proxy.scrollTo(currentMonth.id, anchor: .top)
                }
            } else {
                proxy.scrollTo(currentMonth.id, anchor: .top)
            }
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
            errorMessage = "No saved videos."
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

        // 이미지인지 비디오인지 확인
        // 이미지면 바로 저장, 비디오면 편집 화면으로 이동
        let isImage: Bool = await {
            // 이미지 타입인지 확인
            if let _ = try? await item.loadTransferable(type: PickedImage.self) {
                return true
            }
            return false
        }()

        if isImage {
            // 이미지는 즉시 저장 (로딩 없음)
            await MainActor.run {
                savingDay = day.date
            }
            
            do {
                let clip = try await VideoStorageManager.shared.storeImage(from: item, for: day.date)
                try await ClipStore.shared.upsert(clip.metadata)
                
                await MainActor.run {
                    viewModel.setClip(clip)
                    resetPendingSelection()
                    savingDay = nil
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to save image.\n\(error.localizedDescription)"
                    resetPendingSelection()
                    savingDay = nil
                }
            }
        } else {
            // 비디오는 편집 화면으로 이동
            await MainActor.run {
                editorDraft = EditorDraft(date: day.date, sources: [.picker(item)])
                isShowingPicker = false
                selectedPickerItems = []
            }
        }
    }

    private func deleteClip(_ clip: DayClip) async {
        await MainActor.run {
            savingDay = clip.date
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
                errorMessage = "Failed to delete video.\n\(error.localizedDescription)"
            }
        }

        await MainActor.run {
            savingDay = nil
        }
    }
    
    private func deleteClipForDate(_ date: Date) async {
        await MainActor.run {
            savingDay = date
        }

        do {
            if let clip = viewModel.clip(for: date) {
                try VideoStorageManager.shared.removeClip(clip)
                VideoStorageManager.shared.clearEditingSession(for: date)
                try await ClipStore.shared.deleteClip(for: date)
                await MainActor.run {
                    viewModel.removeClip(for: date)
                    resetPendingSelection()
                }
            } else {
                // 클립이 없어도 편집 세션은 정리
                VideoStorageManager.shared.clearEditingSession(for: date)
                await MainActor.run {
                    resetPendingSelection()
                }
            }
        } catch {
            await MainActor.run {
                errorMessage = "Failed to delete video.\n\(error.localizedDescription)"
            }
        }

        await MainActor.run {
            savingDay = nil
        }
    }

    private func handleEditorCompletion(for date: Date, composition: EditorCompositionDraft?) async {
        await MainActor.run {
            savingDay = date
        }
        
        do {
            if let composition = composition {
                // 클립이 있는 경우: 저장
                let clip = try await VideoStorageManager.shared.exportComposition(
                    draft: composition,
                    date: date
                )

                try await ClipStore.shared.upsert(clip.metadata)
                
                // 편집 정보 저장 (trim 정보 포함)
                let sourceURLs = VideoStorageManager.shared.loadEditingSources(for: date)
                VideoStorageManager.shared.saveEditingComposition(composition, sourceURLs: sourceURLs, for: date)

                await MainActor.run {
                    viewModel.setClip(clip)
                    resetPendingSelection()
                }
            } else {
                // 클립이 없는 경우: 빈 상태로 저장 (기존 클립 삭제)
                if let existingClip = viewModel.clip(for: date) {
                    try VideoStorageManager.shared.removeClip(existingClip)
                    VideoStorageManager.shared.clearEditingSession(for: date)
                    try await ClipStore.shared.deleteClip(for: date)
                }
                
                await MainActor.run {
                    viewModel.removeClip(for: date)
                    resetPendingSelection()
                }
            }
        } catch {
            await MainActor.run {
                errorMessage = "Failed to save edited video.\n\(error.localizedDescription)"
                resetPendingSelection()
            }
        }

        await MainActor.run {
            savingDay = nil
        }
    }

    private func presentEditorForExistingClip(_ clip: DayClip) {
        let sources = VideoStorageManager.shared.loadEditingSources(for: clip.date)
        guard !sources.isEmpty else {
            errorMessage = "Unable to load editing session. Please select a new video."
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

