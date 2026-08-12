import Foundation
let isRight = (11...18).contains(47) || (41...48).contains(47)
let isMesial = true
let siteIndex = isRight ? (isMesial ? 2 : 0) : (isMesial ? 0 : 2)
print("isRight=\(isRight), isMesial=\(isMesial), siteIndex=\(siteIndex)")

