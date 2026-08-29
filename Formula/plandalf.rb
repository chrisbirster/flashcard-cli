class Plandalf < Formula
  desc "Terminal-first spaced-repetition flashcard application"
  homepage "https://github.com/chrisbirster/flashcard-cli"
  version "0.1.0"
  license "MIT"

  depends_on :macos

  on_macos do
    on_arm do
      url "https://github.com/chrisbirster/flashcard-cli/releases/download/v0.1.0/plandalf-v0.1.0-macos-aarch64.tar.gz"
      sha256 "c19d7c5193b52f4fffb0251ac51dcc91e2e16aec15a053336b674684eb0ac27c"
    end

    on_intel do
      url "https://github.com/chrisbirster/flashcard-cli/releases/download/v0.1.0/plandalf-v0.1.0-macos-x86_64.tar.gz"
      sha256 "084f3fc3369071ddd5f11e4197db272de2bf310d280da6e21a68cac141dd4179"
    end
  end

  def install
    bin.install "plandalf"
  end

  test do
    system bin/"plandalf", "--help"
  end
end
