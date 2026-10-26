import QtQuick

// A list of ids as a model that changes in place: an id added or dropped adds
// or drops its row alone, so a Repeater over it keeps the delegates of the
// others (a plain array given to a Repeater makes them all anew). Each row's
// `key` is its id.
QtObject {
    id: list

    property var ids: []
    readonly property ListModel model: ListModel {}

    function sync() {
        const want = (ids || []).filter((id, i, all) => typeof id === "string" && id && all.indexOf(id) === i)
        for (let i = model.count - 1; i >= 0; --i)
            if (want.indexOf(model.get(i).key) < 0)
                model.remove(i)
        for (const id of want) {
            let found = false
            for (let i = 0; i < model.count && !found; ++i)
                found = model.get(i).key === id
            if (!found)
                model.append({ key: id })
        }
    }
    onIdsChanged: sync()
    Component.onCompleted: sync()
}
