class XcodeRunner < Formula
  desc "Build and run Xcode projects from the terminal"
  homepage "https://github.com/thibaudse/xcode-runner"
  url "https://github.com/thibaudse/xcode-runner/releases/download/build-5/xcode-runner-1.0.0-macos.tar.gz"
  sha256 "b927f9910d2497b44829e1815028396ea397766caf5561935d654d254f5dca43"
  version "1.0.0"
  revision 5
  head "https://github.com/thibaudse/xcode-runner.git", branch: "main"

  depends_on :macos

  def install
    bin.install "xcode-runner"
  end

  test do
    output = shell_output("#{bin}/xcode-runner --version")
    assert_match "1.0.0", output
  end
end
