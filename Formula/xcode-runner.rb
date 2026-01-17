class XcodeRunner < Formula
  desc "Build and run Xcode projects from the terminal"
  homepage "https://github.com/thibaudse/xcode-runner"
  url "https://github.com/thibaudse/xcode-runner/releases/download/build-2/xcode-runner-1.0.0-macos.tar.gz"
  sha256 "1edee63239b3efaa24cc6c934eb11d908c571bf1b1a0a71ef2e8d4d785ac9849"
  version "1.0.0"
  revision 2

  depends_on :macos

  def install
    bin.install "xcode-runner"
  end

  test do
    output = shell_output("#{bin}/xcode-runner --version")
    assert_match "1.0.0", output
  end
end
