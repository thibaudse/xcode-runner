class XcodeRunner < Formula
  desc "Build and run Xcode projects from the terminal"
  homepage "https://github.com/thibaudse/xcode-runner"
  url "https://github.com/thibaudse/xcode-runner/releases/download/build-8/xcode-runner-1.0.0-macos.tar.gz"
  sha256 "ec95f656fa90624bf4194dd43b345c2365cbdf66ef78df09ec3dc69ccba75bfa"
  version "1.0.0"
  revision 8
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
