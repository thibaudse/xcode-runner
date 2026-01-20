class XcodeRunner < Formula
  desc "Build and run Xcode projects from the terminal"
  homepage "https://github.com/thibaudse/xcode-runner"
  url "https://github.com/thibaudse/xcode-runner/releases/download/build-7/xcode-runner-1.0.0-macos.tar.gz"
  sha256 "6ed8e03b043cb78e3637dfa9615e333138d5aebb39eff3cd020ffd081b3dd766"
  version "1.0.0"
  revision 7
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
