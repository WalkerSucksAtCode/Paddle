import PaddleCore
import Testing

struct SameSiteTests {
    @Test func subdomainsOfOneSiteMatch() {
        #expect(SitePolicy.isSameSite("drive.usercontent.google.com", "drive.google.com"))
        #expect(SitePolicy.isSameSite("takeout-download-drive.usercontent.google.com", "drive.google.com"))
        #expect(SitePolicy.isSameSite("www.bbc.co.uk", "news.bbc.co.uk"))
        #expect(SitePolicy.isSameSite("Example.com.", "example.com"))
    }

    @Test func otherSitesDiffer() {
        #expect(!SitePolicy.isSameSite("ads.doubleclick.net", "drive.google.com"))
        #expect(!SitePolicy.isSameSite("bbc.co.uk", "itv.co.uk"))
        #expect(!SitePolicy.isSameSite("10.0.0.1", "10.0.0.2"))
        #expect(!SitePolicy.isSameSite("evil.github.io", "victim.github.io"))
        #expect(!SitePolicy.isSameSite("a.bucket.s3.amazonaws.com", "b.s3.amazonaws.com"))
        #expect(SitePolicy.isSameSite("docs.victim.github.io", "victim.github.io"))
    }
}
