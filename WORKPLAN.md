# WORKPLAN — フレーム完全提示 (frame-complete presentation)

2026-11-13。課題: 負荷が高いとき、中途半端に適用された状態(途切れフレーム)が表示されうる。
要件: 「重い場合はロード時間をとったり再生時のフレームを落とすなどして、
1つ1つのフレームを確実に描画できてから次のフレームに移る」。

## 調査で判明した現状

- 描画は WKWebView 内 three.js(WebGL)。Swift 側は .s3dv を WebSocket で流す再生サーバー。
- 受信パケットは `onmessage` で**即時**にシーンへ適用され、rAF 描画ループは独立。
  同期が無いため提示フレームが任意の時点の状態を写す(適用途中も含む)。
- フレーム落ち/描画待機の概念は存在しない。テクスチャは既に「デコード完了後に promote」
  で原子的(白飛びなし)。
- parity レンダラ (`web/main.js`) は sync_web.sh でバイトピン留め → **変更しない**。
  製品レンダラ (`web/viewer.js`) のみ変更。

## 実装

### viewer.js (製品レンダラ)
1. **受信箱**: 検証済みパケットは即適用せず `inbox` へ(順序厳守)。バイト上限
   (既定 256MB)超過時は同期的に排水してメモリを拘束。
2. **提示ループ**: 各tickで
   ① `applyBudgetMs`(既定6ms)を予算に inbox を順次完全適用
   ② シーンに変化があれば `renderer.render` を**1回だけ**
   ③ 提示は常に「パケット境界の完全状態」。予算切れで適用を打ち切った分は
      中間フレームとして落とす(後の完全状態だけ提示)。
   途中で描画を割り込ませない(単一スレッドなので apply→render は原子的)。
3. **dirty 追跡**: 全シーン変更(挿入/削除/クリア/テクスチャ着脱/ワイヤ/fitView)で
   dirty=true。隠蔽中も適用は続け、表示復帰時に最新完全状態を提示。
4. **統計**: presented(提示したフレーム) / dropped(適用したが個別提示しなかった
   状態 = changed − presented) / backlog(未適用)。HUD・メトリクス・autotest に露出。
5. **即時モード**: 従来動作 (`presentation: 'immediate'`) も選択可能に(比較/退避用)。

### Swift 側
- AppSettings: `presentationMode` (frameComplete=既定 / immediate) + `applyBudgetMs`。
  古い設定ファイルが欠損キーで消えないよう `init(from:)` を decodeIfPresent で自作。
- ViewerBoot telemetry: presented/dropped/backlog を読む(probe)。
- AppCore: boot config と live applyConfig に新設定を追加、ViewerMetrics を拡張。
- ControlRouter: `presentation framecomplete|immediate` コマンド、status/snapshot に
  新キー、`settings set applybudgetms <n>`。
- SettingsView: 「提示モード」ピッカー+適用予算ms。
- StudioView インスペクタ: presented/dropped/backlog 表示。
- AutotestController: 製品+frameComplete 時に提示カウンタの存在検証、
  レポートに提示統計を記録。

### 変更しないもの
- native 再生エンジン (ReplayEngine/ReplayClock): 送信ペースと framesSent 語彙は据え置き。
  packet parity (`page packets == framesSent`) の自動検証がそのまま成立する。
- parity レンダラ main.js / index.html: バイトピン留め維持(意図的に旧動作)。

## 検証(配布品質) — 完了 (2026-11-13)

1. `swift test` — 45/45 パス (回帰なし) ✅
2. `scripts/build_app.sh` — release ビルド＋アドホック署名 成功 ✅
3. `scripts/verify_app.sh --quick` — demo_product / demo_parity / const_product 3/3 PASS ✅
4. `scripts/verify_app.sh` フルマトリクス — gt_product_2g / gt_product_384m / model_product / leak_repeat10 7/7 PASS ✅
   - packet parity (`page packets == framesSent`) 全ケース維持
   - presentation backlog 0、コンソールエラーなし、リークなし
5. `scripts/verify_cli.sh` — 21/21 PASS (presentation / applyBudgetMs ライブ切替含む) ✅
6. 手動検証 — prod_gt.s3dv (1.27GB) を frameComplete で再生：packet parity 維持、backlog 0、エラーなし ✅

すべて配布品質基準を満たしました。
