class Deez < Formula
  desc "Terminal-first spaced-repetition system using FSRS"
  homepage "https://github.com/chrisbirster/deez"
  version "0.2.0-rc.4.1"
  license "MIT"

  on_arm do
    url "https://github.com/chrisbirster/deez/releases/download/v0.2.0-rc.4.1/deez-aarch64-apple-darwin.tar.gz"
    sha256 "53dc381158169e1a0e2af10cd5526dbde523e66d0cea1e4dfe6fb0c30a3f6f23"
  end

  on_intel do
    url "https://github.com/chrisbirster/deez/releases/download/v0.2.0-rc.4.1/deez-x86_64-apple-darwin.tar.gz"
    sha256 "883359291ef02ddc191670f82c2344836a093c0632f6af960406f6b4a221cb04"
  end

  depends_on :macos

  def install
    bin.install "deez"
  end

  test do
    assert_match "DEEZ", shell_output("#{bin}/deez --help")
  end
end
