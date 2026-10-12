/// Every `/regex/` rule in EasyList (https://easylist.to, GPLv3 / CC BY-SA 3.0), version 202610121638: the set
/// `FilterListConverterTests.easyListRegexSetCompilesQuickly` converts and compiles with WebKit.
let easyListRegexRules = #"""
/(https?:\/\/)\w{30,}\.me\/\w{30,}\./$script,third-party
/(https?:\/\/)104\.154\..{100,}/
/(https?:\/\/)104\.197\..{100,}/
/(https?:\/\/)104\.198\..{100,}/
/(https?:\/\/)130\.211\..{100,}/
/(https?:\/\/)142\.91\.159\..{100,}/
/(https?:\/\/)213\.32\.115\..{100,}/
/(https?:\/\/)216\.21\..{100,}/
/(https?:\/\/)217\.182\.11\..{100,}/
/(https?:\/\/)51\.195\.31\..{100,}/
/^https?:\/\/(35|104)\.(\d){1,3}\.(\d){1,3}\.(\d){1,3}\//$popup,third-party
/^https?:\/\/146\.59\.211\.(\d){1,3}.*/$popup,third-party
/^https?:\/\/s3\.*\.amazonaws\.com\/[a-f0-9]{45,}\/[a-f,0-9]{8,10}$/$script,third-party,xmlhttprequest,domain=~amazon.com
/^https?:\/\/.*\.(club|bid|biz|xyz|site|pro|info|online|icu|monster|buzz|website|biz|re|casa|top|one|space|network|live|systems|ml|world|life|co)\/.*/$~image,~media,~subdocument,third-party,domain=1cloudfile.com|adblockstreamtape.art|adblockstreamtape.site|bowfile.com|clipconverter.cc|desiupload.co|dood.la|dood.pm|dood.so|dood.to|dood.watch|dood.ws|dopebox.to|downloadpirate.com|drivebuzz.icu|embedstream.me|eplayvid.net|fmovies.ps|gospeljingle.com|kissanimes.net|movies2watch.tv|myflixer.today|myflixertv.to|powvideo.net|scloud.online|skidrowcodex.net|streamtape.com|theproxy.ws|vidembed.cc|vidembed.io|vidlii.com|vidoo.org|vipbox.lc
/\/[0-9a-f]{32}\/invoke\.js/$script,third-party
/^https?:\/\/www\.[0-9a-z]{8,}\.com\/[0-9a-z]{1,4}\.js$/$script,third-party,domain=dood.la|dood.pm|dood.sh|dood.so|dood.to|dood.watch|dood.ws
/\.gsmarena\.com\/[0-9]+\.[a-z]+\?s?Search=/$xmlhttprequest,domain=gsmarena.com
/^https?:\/\/.*\.(club|xyz|top|casa)\//$popup,domain=databasegdriveplayer.co|dood.la|dood.so|dood.to|dood.video|dood.watch|dood.ws|doodcdn.com|fmovies.world|masafun.com|strtpe.link|voe-unblock.com
/^https?:\/\/.*\.(club|news|live|online|store|tech|guru|cloud|bid|xyz|site|pro|info|online|icu|monster|buzz|fun|website|photos|re|casa|top|today|space|network|live|work|systems|ml|world|life)\/.*/$~media,domain=1vag.com|4tube.com|asianpornmovies.com|getsex.xxx|glam0ur.com|hclips.com|hdzog.com|homemadevids.org|hotmovs.com|justthegays.com|milfzr.com|porn555.com|pornforrelax.com|pornj.com|pornl.com|puporn.com|see.xxx|shemalez.com|sss.xxx|streanplay.cc|thegay.com|thegay.porn|tits-guru.com|tubepornclassic.com|tuberel.com|txxx.com|txxx.tube|upornia.com|vjav.com|voyeurhit.com|xozilla.com
/^https?:\/\/.*\/.*sw[0-9._].*/$script,xmlhttprequest,domain=1vag.com|4tube.com|adult-channels.com|analdin.com|biguz.net|bogrodius.com|chikiporn.com|fantasti.cc|fuqer.com|fux.com|hclips.com|heavy-r.com|hog.tv|megapornx.com|milfzr.com|mypornhere.com|porn555.com|pornchimp.com|pornerbros.com|pornj.com|pornl.com|pornototale.com|porntube.com|sexu.com|sss.xxx|thisav.com|titkino.net|tubepornclassic.com|tuberel.com|tubev.sex|txxx.com|vidmo.org|vpornvideos.com|xozilla.com|youporn.lc|youpornhub.it|yourdailypornstars.com
/^https?:\/\/.*\/[a-z0-9A-Z_]{2,15}\.(php|jx|jsx|1ph|jsf|jz|jsm|j$)/$script,subdocument,domain=3movs.com|4kporn.xxx|4tube.com|alotporn.com|alphaporno.com|alrincon.com|amateur8.com|anyporn.com|badjojo.com|bdsmstreak.com|bestfreetube.xxx|bigtitslust.com|bravotube.net|cockmeter.com|crazyporn.xxx|daftporn.com|ebony8.com|erome.com|exoav.com|fantasti.cc|fapality.com|fapnado.com|fetishshrine.com|freeporn8.com|gfsvideos.com|gotporn.com|hdporn24.org|hdpornmax.com|hdtube.porn|hellporno.com|hentai2w.com|hottorrent.org|hqsextube.xxx|hqtube.xxx|iceporn.com|imgderviches.work|imx.to|its.porn|katestube.com|lesbian8.com|love4porn.com|lustypuppy.com|manga18fx.com|manhwa18.cc|maturetubehere.com|megatube.xxx|milffox.com|momxxxfun.com|openloadporn.co|orsm.net|pervclips.com|porn-plus.com|porndr.com|pornicom.com|pornid.xxx|pornotrack.net|pornrabbit.com|pornwatchers.com|pornwhite.com|pussy.org|redhdtube.xxx|rule34.art|rule34pornvids.com|runporn.com|sexvid.porn|sexvid.pro|sexvid.xxx|sexytorrents.info|shameless.com|sleazyneasy.com|sortporn.com|stepmom.one|stileproject.com|str8ongay.com|tnaflix.com|urgayporn.com|vikiporn.com|wankoz.com|xbabe.com|xcafe.com|xhqxmovies.com|xxx-torrent.net|xxxdessert.com|xxxextreme.org|xxxonxxx.com|yourlust.com|youx.xxx|zbporn.com|zbporn.tv
/about:blank.*/$popup,domain=bitporno.com|iceporn.com|katestube.com|videowood.tv
"""#
