<p align="center">
  <img src="docs/images/sumra-brand.png" alt="Sumra — macOS 向けの軽量なオープンソースリーダー" width="720">
</p>

# Sumra — 軽量な macOS リーダー

**電子書籍、コミック、PDF、画像、Markdown。読書に集中できるネイティブ Mac アプリです。**

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · **日本語**

**macOS 13 以降 · Apple Silicon · 無料・オープンソース**

[**Mac 版をダウンロード**](https://github.com/Ares-X/Sumra/releases/latest) · [リリースノート](https://github.com/Ares-X/Sumra/releases) · [対応形式](#対応形式) · [ソースからビルド](#ソースからビルド) · [問題を報告](https://github.com/Ares-X/Sumra/issues)

Finder から EPUB 小説、コミックアーカイブ、画像フォルダ、Markdown メモ、PDF を開けます。Mac のネイティブウィンドウやタブで読み、レイアウトを選び、目次、検索、ブックマークで読みたい場所を見つけられます。

![ライトモードで Markdown の読書メモと目次を表示する Sumra](docs/images/reader-light.png)

<details>
<summary>スクリーンショットをもっと見る：見開き表示、最近使ったファイル、ダークモード</summary>

![目次サイドバー付きの見開き表示](docs/images/reader-two-pages.png)

![ホーム画面の最近使った書類](docs/images/home-light.png)

![ダークモードでの読書](docs/images/reader-dark.png)

すべてのスクリーンショットには、リポジトリ内の[デモ用原稿](docs/demos/Reading-Notes.md)を使用しています。

</details>

## インストールして読書を始める

1. [最新リリース](https://github.com/Ares-X/Sumra/releases/latest)からアプリの ZIP をダウンロードして展開します。
2. **Sumra.app** を **アプリケーション** に移動して開きます。
3. **⌘O** を押すか、ウィンドウにファイルをドラッグします。文書内のテキストを検索するには **⌘F** を押します。

公開ビルドには Apple Developer ID 証明書ではなく、メンテナーの自己署名証明書 **Ares-X Code Signing** を使用しており、公証されていません。初回起動時に macOS がブロックし、ダウンロード元を信頼できる場合は、[Apple の手順](https://support.apple.com/ja-jp/102445)に従って、**システム設定 → プライバシーとセキュリティ → このまま開く** を選び、確認してください。

**アップデート：** **Help → 更新を確認…（Check for Updates…）** を選ぶか、設定で **Automatically check for updates** を有効にします。Sparkle がアップデートを検証し、確認後にインストールします。各リリースには対応するソースコードと SHA-256 チェックサムも含まれます。

<details>
<summary>互換性と旧バージョンからの移行</summary>

リリースの対象は **Apple Silicon（arm64）** と **macOS 13 以降** です。同梱の実行ファイルとライブラリについて、arm64 対応、デプロイメントターゲット、実行時依存関係を確認しています。macOS 27.0.1 で GUI の受け入れ確認を行っています。実機の macOS 13 ではまだ確認していません。

バージョン 0.2.0 にはアップデートフィードがありません。新しいリリースを手動で一度インストールしてください。0.2.1 以降はアプリ内アップデートに対応しています。PostScript と EPS の利用には Ghostscript の別途インストールが必要です。

</details>

## 読書のための機能

- **ネイティブのウィンドウとタブ。** Finder から開く、ファイルを Sumra にドラッグする、ホームから続ける、といった方法で読書を始められます。複数の本をまとめるには、設定で **Use window tabs** を有効にします。
- **文書に合わせたレイアウト。** 1 ページ、連続スクロール、見開き表示を切り替えられ、テーマや文字組みも調整できます。リフロー型の本はウィンドウに合わせて表示され、固定ページは元のページ構成を保ちます。
- **読みたい場所を探す。** 目次、章タイトル検索、全文検索、サムネイル、ブックマーク、任意の読書位置履歴を利用できます。TXT と MOBI では、作成者による目次がない場合に独立した章タイトルを検出できます。
- **コミックコレクションを移動する。** アーカイブ内のフォルダを、名前と階層を保った目次項目として表示します。対応するソリッド LZMA2 アーカイブでは、メモリ上のセクションインデックスを使って離れた位置へ移動できます。元ファイルは変更せず、展開済みの本のキャッシュも書き込みません。
- **PDF を操作する。** フォーム入力、注釈の編集、元に戻す・やり直し、ページの抽出や結合、変更の保存ができます。PDF の編集は **Enable Editing** を選ぶまでロックされています。**Save a Copy…** では編集可能なフォームと注釈を保持し、**Export PDF…** では閲覧用の静的なコピーを作成します。
- **読み上げ、印刷、書き出し。** システム音声でテキストや選択範囲を読み上げる、macOS の印刷パネルから印刷する、PDF に書き出す、といった操作ができます。利用できる操作は形式と文書の権限によって異なります。

サイドバーでは目次、サムネイル、ブックマークを使えます。**View** メニューでレイアウトやテーマを、設定で文字組み、履歴、タブを調整できます。コマンドは **Help → キーボードショートカット（Keyboard Shortcuts）** で確認でき、設定でショートカットを変更できます。

5 種類の組み込みテーマから選ぶか、文字・背景・リンクの色をカスタマイズして保存できます。既存のカスタムテーマと保存済み設定も引き続き利用できます。

![Sumra の 5 種類の組み込み読書テーマ](docs/images/themes.png)

## 対応形式

| 種類 | 形式 |
| --- | --- |
| PDF と固定ページ | PDF、XPS / OXPS、SVG、DjVu |
| 電子書籍 | EPUB、MOBI、AZW、PRC、FB2 / 圧縮 FB2 |
| コミックと画像 | CBZ、CBR、CB7、CBT、画像フォルダ、GIF、TIFF、JPEG XL など一般的な画像形式 |
| テキストと Web | Markdown、HTML / XHTML、CHM、TXT などのプレーンテキスト、TCR |
| その他の対応形式 | PDF 対応 AI、P7M エンベロープ、LIT |
| 追加ソフトウェアが必要 | PostScript / EPS：Ghostscript を別途インストールしてください |

対応状況はファイルのバリエーションによって異なります。Sumra は OCR と DRM の解除には対応していません。スキャンしたページのテキスト検索には、既存のテキストレイヤーが必要です。

<details>
<summary>描画に関する補足と形式の制限</summary>

- Markdown の描画には MuPDF を使い、オプションで WebKit 互換モードを利用できます。HTML と CHM の閲覧には WebKit を使いますが、印刷と PDF 書き出しには MuPDF のレイアウトを使うため、閲覧画面と見た目が異なる場合があります。
- リフロー型電子書籍とネイティブ Markdown では、冗長な空白行や空の段落を詰めます。整形済みテキスト、表、画像ブロック、明示的な改ページはそのまま保ちます。認識された CHM の本文も段落間隔を詰めます。フォント、サイズ、行間を変更すると、発行元のスタイル設定は適用されなくなります。
- PDF の白黒の文字スキャンは自動的にコントラストを調整します。元の表示を確認するには **View → Document Colors → Enhance Scanned Pages** をオフにします。元ファイルは変更されません。
- セクションインデックスを使うと、対応するコミックアーカイブでは前方の独立したセクションを読み飛ばせます。最初に移動する際は、対象セクションの先頭から移動先までのデータをデコードする必要があります。まだ開いていない場所への移動が常に瞬時になるわけではありません。

[形式とエンジンの対応状況](docs/SUMATRA_ENGINE_PARITY.md)、[Markdown の描画](docs/MARKDOWN_RENDERER_DECISION.md)、[コミックのセクション移動](docs/COMIC_SEEK_INDEX_20261020.md)で詳細を確認できます。

</details>

## ソースからビルド

macOS、Apple Swift ツールチェーンと macOS SDK、CMake が必要です。初回ビルドでは、固定バージョンのネイティブ依存関係と Sparkle を取得するためインターネット接続が必要です。プロジェクトのビルドとパッケージングのスクリプトは Swift とシステムツールを使います。Python は必要ありません。

```sh
git clone https://github.com/Ares-X/Sumra.git
cd Sumra
./scripts/build-app.sh --release
open dist/Sumra.app
```

必要に応じて、パッケージマネージャーで CMake をインストールしてください（例：`brew install cmake`）。開発ビルドを起動するには `./scripts/run-dev.sh` を使います。ローカルビルドはデフォルトで ad-hoc 署名されます。

Sumra は GUI アプリケーションです。ファイルを開く操作、文書ツール、印刷にはアプリのインターフェースを使います。開発については、[実装状況](docs/IMPLEMENTATION_STATUS.md)、[ローカルチェック](scripts/check-source.sh)、[リリース手順](docs/RELEASE_ACTIONS.md)を参照してください。

## 貢献と翻訳

設定では、よく使われる25の言語・地域を選べます。管理対象の画面文言は翻訳済みで、母語話者による改善も歓迎します。本文の文字表示は埋め込み・同梱・インストール済みフォントに依存します。対応一覧、検証範囲、組版の制限は[言語対応と検証](docs/LANGUAGE_SUPPORT.md)をご覧ください。

[バグ報告と機能リクエスト](https://github.com/Ares-X/Sumra/issues)やプルリクエストを歓迎します。可能であれば、macOS と Sumra のバージョン、ファイル形式、再現手順、共有可能なサンプルを記載してください。

README は英語、簡体字中国語、繁体字中国語、日本語で読めます。内容の基準として [README.md](README.md) を参照し、セクションの順序を揃えてください。共通情報が変わった場合は、他の言語版も更新してください。すべての言語版で同じスクリーンショットを使い、技術文書へリンクしています。

<!-- community-contributors:start -->
## コミュニティ貢献者

Issue の報告、コードの提供、レビューを通じて Sumra を改善してくださる皆さんに感謝します。この一覧は対象の GitHub Issue とマージ済み Pull Request から自動更新されます。

| 貢献者 | 貢献内容 |
| --- | --- |
| <a href="https://github.com/HomeStarRunnerTron"><img src="https://github.com/HomeStarRunnerTron.png?size=80" alt="@HomeStarRunnerTron" width="40"></a> [@HomeStarRunnerTron](https://github.com/HomeStarRunnerTron) | 📝 [Issue #31](https://github.com/Ares-X/Sumra/issues/31) [Issue #42](https://github.com/Ares-X/Sumra/issues/42) |
| <a href="https://github.com/2924661311"><img src="https://github.com/2924661311.png?size=80" alt="@2924661311" width="40"></a> [@2924661311](https://github.com/2924661311) | 📝 [Issue #48](https://github.com/Ares-X/Sumra/issues/48) |

<!-- community-contributors:end -->

## ライセンスと謝辞

Sumra の新規コードは **[AGPL-3.0-or-later](LICENSE)** でライセンスされています。上流から取り込んだコンポーネントと移植したコンポーネントは、それぞれのライセンスと著作権表示を引き継ぎます。出典、バージョン、ライセンスは [THIRD_PARTY.md](THIRD_PARTY.md) を参照してください。

[SumatraPDF](https://github.com/sumatrapdfreader/sumatrapdf) に着想を得て、Sumra は MuPDF と SumatraPDF の文書処理の一部を、SwiftUI と AppKit のインターフェースで再利用しています。[MuPDF](https://mupdf.com/) とその他の上流プロジェクトに感謝します。Sumra は独立して開発されており、機能の対応状況と残る差異は[比較資料](docs/SUMATRA_PARITY.md)に記載しています。
