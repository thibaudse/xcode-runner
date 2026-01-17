class XcodeRunner < Formula
  desc "Build and run Xcode projects from the terminal"
  homepage "https://github.com/thibaudse/xcode-runner"
  head "https://github.com/thibaudse/xcode-runner.git", branch: "main"

  depends_on :macos

  def install
    system "swift", "build", "-c", "release"
    bin.install ".build/release/xcode-runner"
  end

  test do
    output = shell_output("#{bin}/xcode-runner --version")
    assert_match "xcode-runner", output
  end
end
