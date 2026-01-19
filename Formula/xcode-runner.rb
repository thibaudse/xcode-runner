class XcodeRunner < Formula
  desc "Build and run Xcode projects from the terminal"
  homepage "https://github.com/thibaudse/xcode-runner"
  url "https://github.com/thibaudse/xcode-runner/releases/download/build-6/xcode-runner-1.0.0-macos.tar.gz"
  sha256 "0d8b9111d9226c9fc1f5684f2d0efb6ded7d346a93fa6e61f6b1b4a20496384a"
  version "1.0.0"
  revision 6
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
