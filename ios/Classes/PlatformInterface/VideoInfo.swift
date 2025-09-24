struct VideoInfo {
    let height: Int
    let width: Int
    let duration: Int64

    func toMap() -> [String: Any] {
        [
            "height": height,
            "width": width,
            "duration": duration
        ]
    }
}
