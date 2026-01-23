class XcodeRunner < Formula
  desc "Build and run Xcode projects from the terminal"
  homepage "https://github.com/thibaudse/xcode-runner"
  url "https://github.com/thibaudse/xcode-runner/releases/download/build-9/xcode-runner-1.0.0-macos.tar.gz"
  sha256 "172c861b1e365ee0e1c225c1f0ca601be29afdc4681c27335ab1e551199bada4"
  version "1.0.0"
  revision 9
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
