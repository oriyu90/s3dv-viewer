# s3dv-viewer — 保守メモ（非公開）

このファイルには、次回以降の開発・バージョンアップ時に更新すべき箇所など、
公開物（README / 紹介サイト / リリースノート）には出さない保守情報を集約する。
（common rules.md ルール6）

## バージョン履歴
- v1.2.0 (build 12): フレーム完全提示、日英バイリンガルUI、s3dvctl presentation/applybudgetms 追加

## 次回アップデート時に検討すべき項目
- zh / pt 言語の SwiftUI 文字列リソース（現在は en.lproj のみ + viewer.js/statusbar の 4 か国語対応）
- テクスチャ付き録画のパリティ検証強化
- 4D volume / オーディオ / アニメーション補間への対応検討
- 将来の Apple Developer Program 移行に備えた Developer ID 署名 / 公証対応（現状は ad-hoc 署名・未公証）

## 署名・配布に関する注意（common rules.md ルール8）
- macOS アプリは ad-hoc 署名（`codesign --sign -`）でリリース。Apple Developer Program 未加入。
- README・リリースノート・紹介サイトに「Developer ID 署名済み」「Apple 公証済み」等の実態と異なる記述をしないこと。
- 初回起動時に「システム設定 > プライバシーとセキュリティ」からの許可が必要である旨を記載すること。

## 関連リポジトリ
- 研究リポジトリ: /Users/yuki/Places_M1/研究/S3DV_研究/apps/s3dv-viewer（ローカル、リモートなし）
- 紹介サイト: oriyu90/studio-rizi (website/projects/s3dv-viewer/) → https://studio-rizi.pages.dev/projects/s3dv-viewer/
