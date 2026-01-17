class XcodeRunner < Formula
  desc "Build and run Xcode projects from the terminal"
  homepage "https://github.com/thibaudse/xcode-runner"
  url "https://github.com/thibaudse/xcode-runner/releases/download/build-4/xcode-runner-1.0.0-macos.tar.gz"
  sha256 "fc2e4052591a556aecf6a4c82c128a9d5340e6a98e84657e33cb9720b88b5b41"
  version "1.0.0"
  revision 4
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
