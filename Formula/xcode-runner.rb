class XcodeRunner < Formula
  desc "Build and run Xcode projects from the terminal"
  homepage "https://github.com/thibaudse/xcode-runner"
  url "https://github.com/thibaudse/xcode-runner/releases/download/build-3/xcode-runner-1.0.0-macos.tar.gz"
  sha256 "edafae78c24ba7d5565b6e7241a54067347998d8f2f17b4c06a76e1715240323"
  version "1.0.0"
  revision 3

  depends_on :macos

  def install
    bin.install "xcode-runner"
  end

  test do
    output = shell_output("#{bin}/xcode-runner --version")
    assert_match "1.0.0", output
  end
end
