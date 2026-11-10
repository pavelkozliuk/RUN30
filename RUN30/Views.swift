import SwiftUI
import Combine

private func number(_ n: Double) -> String { String(format:"%.2f", n) }
private func pace(_ secondsPerKm: Double?) -> String {
    guard let x = secondsPerKm, x > 0, x.isFinite else { return "—" }
    let sec = Int(x.rounded())
    return String(format:"%d:%02d мин/км", sec/60,sec%60)
}
private func duration(_ total: Double) -> String {
    let t = Int(max(0,total))
    return String(format:"%02d:%02d:%02d",t/3600,t%3600/60,t%60)
}

struct MainTabs: View {
    @EnvironmentObject var cloud: CloudStore
    @State private var selected = 0
    var body: some View {
        TabView(selection:$selected) {
            NavigationStack { HomeScreen().navigationTitle("RUN30") }
                .tabItem { Label("Сегодня", systemImage:"house.fill") }.tag(0)
            NavigationStack { PlanScreen().navigationTitle("26 недель") }
                .tabItem { Label("План", systemImage:"calendar") }.tag(1)
            NavigationStack { GPSView().navigationTitle("GPS-тренировка") }
                .tabItem { Label("GPS", systemImage:"location.fill") }.tag(2)
            NavigationStack { JournalScreen().navigationTitle("Журнал") }
                .tabItem { Label("Журнал", systemImage:"list.bullet.clipboard") }.tag(3)
            NavigationStack { SettingsScreen().navigationTitle("Настройки") }
                .tabItem { Label("Облако", systemImage:"cloud") }.tag(4)
        }
    }
}

struct HomeScreen: View {
    @EnvironmentObject var cloud: CloudStore
    var total: Double { cloud.records.values.reduce(0) { $0 + $1.distance } }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                VStack(alignment:.leading,spacing:8) {
                    Text("ПУТЬ К 30 КМ").font(.caption).fontWeight(.bold).tracking(2).foregroundStyle(.green)
                    Text("Беги в своём темпе").font(.system(size:29,weight:.heavy))
                    Text("Цель — 30 км без остановки, но не ценой боли или перегрузки.")
                        .foregroundStyle(.secondary)
                }.padding(.top,12)
                HStack(spacing:10) {
                    summaryTile("Пробежек","\(cloud.records.count)","figure.run")
                    summaryTile("Всего", "\(number(total)) км", "point.topleft.down.curvedto.point.bottomright.up")
                }
                VStack(alignment:.leading,spacing:12) {
                    Text("Ближайшие тренировки").font(.title3).bold()
                    ForEach(0..<4,id:\.self) { index in
                        let week = min(26,TrainingPlan.activeWeek(startISO:cloud.startDate) + index)
                        HStack {
                            VStack(alignment:.leading) {
                                Text("Неделя \(week)").bold()
                                Text("Длительная: \(number(TrainingPlan.planned(week,3))) км")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(number(TrainingPlan.distances[week - 1].reduce(0,+))) км")
                                .foregroundStyle(.green).bold()
                        }
                        Divider()
                    }
                    Text("Первые недели — лёгкий бег; при одышке чередуй бег и ходьбу.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding().background(.thinMaterial,in:RoundedRectangle(cornerRadius:16))
                statusCard
            }.padding()
        }.refreshable { await cloud.sync() }
    }
    private var statusCard: some View {
        VStack(alignment:.leading,spacing:8) {
            Label("Синхронизация", systemImage:"cloud") .font(.headline)
            Text(cloud.status).font(.subheadline)
            if let error = cloud.errorText { Text(error).font(.caption).foregroundStyle(.orange) }
            if cloud.pendingCount > 0 { Text("Локальная очередь: \(cloud.pendingCount)").font(.caption) }
            Button("Синхронизировать сейчас") { Task { await cloud.sync() } }
                .buttonStyle(.bordered)
        }.frame(maxWidth:.infinity,alignment:.leading).padding()
         .background(.thinMaterial,in:RoundedRectangle(cornerRadius:16))
    }
    private func summaryTile(_ label:String,_ value:String,_ icon:String)->some View {
        VStack(alignment:.leading,spacing:10) {
            Image(systemName:icon).font(.title3).foregroundStyle(.green)
            Text(value).font(.title2).bold()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth:.infinity,alignment:.leading).padding()
         .background(.thinMaterial,in:RoundedRectangle(cornerRadius:16))
    }
}

struct PlanScreen: View {
    @EnvironmentObject var cloud: CloudStore
    @State private var week = 1
    @State private var editingDay: Int? = nil
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:14) {
                HStack {
                    Button { week = max(1,week-1) } label: { Image(systemName:"chevron.left").font(.title3) }
                    Spacer()
                    VStack(spacing:2) {
                        Text("Неделя \(week) / 26").font(.headline)
                        Text("\(number(TrainingPlan.distances[week-1].reduce(0,+))) км по плану")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { week = min(26,week+1) } label: { Image(systemName:"chevron.right").font(.title3) }
                }.padding()
                ForEach(0..<4,id:\.self) { day in
                    HStack(spacing:12) {
                        Image(systemName:cloud.records[TrainingPlan.key(week,day)] == nil ? "circle" : "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        VStack(alignment:.leading,spacing:4) {
                            Text(TrainingPlan.dayNames[day]).font(.headline)
                            Text("\(TrainingPlan.display(TrainingPlan.date(startISO:cloud.startDate,week:week,day:day))) · по плану \(number(TrainingPlan.planned(week,day))) км")
                                .font(.caption).foregroundStyle(.secondary)
                            if let r = cloud.records[TrainingPlan.key(week,day)] {
                                Text("Факт: \(number(r.distance)) км · \(pace((r.minutes ?? 0) * 60 / max(0.01,r.distance)))")
                                    .font(.caption).foregroundStyle(.green)
                            }
                        }
                        Spacer()
                        Button("Записать") { editingDay = day }
                            .font(.caption).buttonStyle(.bordered)
                    }.padding().background(.thinMaterial,in:RoundedRectangle(cornerRadius:14))
                }
                VStack(alignment:.leading,spacing:10) {
                    Text("Проверка готовности к следующей неделе").font(.headline)
                    ForEach(TrainingPlan.readiness.indices,id:\.self) { idx in
                        Toggle(TrainingPlan.readiness[idx],isOn:Binding(
                            get:{cloud.ready["\(week)-\(idx)"] ?? false},
                            set:{cloud.updateReady(week:week,index:idx,value:$0); Task { await cloud.sync() }}
                        )).font(.subheadline)
                    }
                    Text("Если есть боль, необычная одышка или не восстановился, повтори неделю вместо увеличения нагрузки.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding().background(.thinMaterial,in:RoundedRectangle(cornerRadius:14))
            }.padding()
        }
        .sheet(item:Binding(get: { editingDay.map { DayIndex(value:$0) } },set:{ editingDay=$0?.value })) { item in
            ManualEntryView(week:week,day:item.value)
        }
        .refreshable { await cloud.sync() }
        .onAppear { week = TrainingPlan.activeWeek(startISO:cloud.startDate) }
    }
}
private struct DayIndex: Identifiable { let value:Int; var id:Int {value} }

struct ManualEntryView: View {
    @EnvironmentObject var cloud: CloudStore
    @Environment(\.dismiss) private var dismiss
    let week:Int
    let day:Int
    @State private var km = ""
    @State private var minutes = ""
    @State private var rpe = 3
    @State private var pain = false
    @State private var note = ""
    private var recordKey:String { TrainingPlan.key(week,day) }
    var body: some View {
        NavigationStack {
            Form {
                Section("Результат") {
                    TextField("Дистанция, км",text:$km).keyboardType(.decimalPad)
                    TextField("Время, минуты",text:$minutes).keyboardType(.decimalPad)
                    Stepper("Нагрузка: \(rpe)/10",value:$rpe,in:1...10)
                    Toggle("Была боль или необычный симптом",isOn:$pain)
                    TextField("Заметки",text:$note,axis:.vertical).lineLimit(3...5)
                }
                if cloud.records[recordKey]?.gps != nil {
                    Section { Text("GPS-маршрут сохранится при изменении этой записи.") }
                }
                Section {
                    Button("Сохранить") { save() }
                        .disabled((Double(km.replacingOccurrences(of:",",with:".")) ?? 0) <= 0)
                }
            }
            .navigationTitle("Неделя \(week) · \(TrainingPlan.dayShort[day])")
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Закрыть") {dismiss()} } }
            .onAppear {
                if let r = cloud.records[recordKey] {
                    km = number(r.distance)
                    minutes = r.minutes.map {number($0)} ?? ""
                    rpe = r.rpe; pain = r.pain; note = r.notes
                } else { km = number(TrainingPlan.planned(week,day)) }
            }
        }
    }
    private func save() {
        guard let dist=Double(km.replacingOccurrences(of:",",with:".")),dist>0,dist<=100 else { return }
        let mins=Double(minutes.replacingOccurrences(of:",",with:"."))
        let existing=cloud.records[recordKey]
        let r = RunRecord(distance:dist,minutes:mins,rpe:rpe,pain:pain,notes:note,
                          updatedAt:Date().isoString,startedAt:existing?.startedAt,gps:existing?.gps)
        cloud.saveRecord(r,week:week,day:day)
        Task { await cloud.sync() }
        dismiss()
    }
}

struct GPSView: View {
    @EnvironmentObject var gps: GPSTracker
    @EnvironmentObject var cloud: CloudStore
    @State private var week=1
    @State private var day=0
    @State private var rpe=3
    @State private var pain=false
    @State private var notes=""
    @State private var confirmReplace=false
    @State private var confirmDiscard=false
    @State private var savedNotice=false
    private let ticker=Timer.publish(every:1,on:.main,in:.common).autoconnect()
    private var currentWeek:Int { gps.hasDraft ? gps.session.week : week }
    private var currentDay:Int { gps.hasDraft ? gps.session.day : day }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:14) {
                if gps.session.mode == .idle {
                    HStack {
                        Picker("Неделя",selection:$week) { ForEach(1...26,id:\.self){ Text("\($0)").tag($0) } }
                        Picker("День",selection:$day) { ForEach(0..<4,id:\.self){ Text(TrainingPlan.dayShort[$0]).tag($0) } }
                    }.pickerStyle(.menu)
                } else {
                    Text("Неделя \(currentWeek) · \(TrainingPlan.dayNames[currentDay])")
                        .font(.headline)
                }
                HStack(spacing:12) {
                    metric("Дистанция","\(number(gps.distanceKm))","км")
                    metric("Активное время",duration(gps.seconds),"")
                }
                metric("Средний темп",pace(gps.paceSecondsPerKm),"")
                if !gps.session.points.isEmpty {
                    RouteMap(points:gps.session.points)
                        .frame(height:260).clipShape(RoundedRectangle(cornerRadius:16))
                } else {
                    RoundedRectangle(cornerRadius:16).fill(Color.green.opacity(0.08))
                        .overlay { VStack(spacing:10) {
                            Image(systemName:"location.north.circle").font(.largeTitle)
                            Text("Маршрут появится после GPS-фиксации").font(.caption)
                        }.foregroundStyle(.secondary) }
                        .frame(height:170)
                }
                Label(gps.session.info,systemImage:"location.circle")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Разрешение: \(gps.permission) · GPS-точек: \(gps.session.points.count) · отклонено: \(gps.session.rejected)")
                    .font(.caption2).foregroundStyle(.secondary)
                controls
                if gps.session.mode == .finished { saveForm }
                Text("Запись фонового GPS работает только во время активной тренировки. Не закрывай RUN30 принудительно; iOS всё равно может прекратить процесс. На iPhone при первом запуске разреши геолокацию.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding()
        }
        .onReceive(ticker) { _ in gps.pulse() }
        .alert("Заменить существующую тренировку?",isPresented:$confirmReplace) {
            Button("Заменить",role:.destructive) { save() }
            Button("Отмена",role:.cancel) {}
        } message: { Text("Прежняя запись и GPS-маршрут будут заменены на обоих устройствах после синхронизации.") }
        .alert("Удалить несохранённый маршрут?",isPresented:$confirmDiscard) {
            Button("Удалить",role:.destructive) { gps.discard() }
            Button("Отмена",role:.cancel) {}
        } message:{ Text("Черновик GPS нельзя будет восстановить.") }
        .alert("Пробежка сохранена",isPresented:$savedNotice) { Button("ОК",role:.cancel){} }
    }
    @ViewBuilder private var controls: some View {
        switch gps.session.mode {
        case .idle:
            Button { gps.start(week:week,day:day) } label: {
                Label("Начать GPS-пробежку",systemImage:"play.fill").frame(maxWidth:.infinity)
            }.buttonStyle(.borderedProminent).controlSize(.large)
        case .running:
            HStack {
                Button { gps.pause() } label: { Label("Пауза",systemImage:"pause.fill") }
                    .buttonStyle(.bordered).frame(maxWidth:.infinity)
                Button { gps.finish() } label: { Label("Завершить",systemImage:"stop.fill") }
                    .buttonStyle(.borderedProminent).frame(maxWidth:.infinity)
            }
        case .paused:
            HStack {
                Button("Продолжить") { gps.resume() }.buttonStyle(.borderedProminent)
                Button("Завершить") { gps.finish() }.buttonStyle(.bordered)
            }
        case .finished: EmptyView()
        }
        if gps.hasDraft {
            Button("Удалить черновик",role:.destructive) { confirmDiscard=true }.font(.footnote)
        }
    }
    @ViewBuilder private var saveForm: some View {
        VStack(alignment:.leading,spacing:10) {
            Text("Сохранить пробежку в общий журнал").font(.headline)
            Stepper("Сложность: \(rpe)/10",value:$rpe,in:1...10)
            Toggle("Была боль или необычный симптом",isOn:$pain)
            TextField("Заметки",text:$notes,axis:.vertical).lineLimit(3...5)
                .textFieldStyle(.roundedBorder)
            Button("Сохранить и синхронизировать") {
                let k=TrainingPlan.key(currentWeek,currentDay)
                if cloud.records[k] != nil { confirmReplace=true }
                else { save() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(gps.distanceKm < 0.1)
            Text("Для сохранения требуется хотя бы 100 м записанной дистанции.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding().background(.thinMaterial,in:RoundedRectangle(cornerRadius:16))
    }
    private func save() {
        cloud.saveRecord(gps.makeRecord(rpe:rpe,pain:pain,notes:notes),week:currentWeek,day:currentDay)
        gps.discard() // only after locally persisted in CloudStore
        notes="";rpe=3;pain=false
        savedNotice=true
        Task { await cloud.sync() }
    }
    private func metric(_ label:String,_ value:String,_ unit:String)->some View {
        VStack(alignment:.leading,spacing:5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size:26,weight:.bold,design:.rounded)).minimumScaleFactor(0.6).lineLimit(1)
            if !unit.isEmpty { Text(unit).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth:.infinity,alignment:.leading).padding(14)
         .background(.thinMaterial,in:RoundedRectangle(cornerRadius:14))
    }
}

struct JournalScreen: View {
    @EnvironmentObject var cloud: CloudStore
    @State private var selected: String? = nil
    @State private var confirmDelete: String? = nil
    private var keys: [String] {
        cloud.records.keys.sorted { a,b in
            let x=a.split(separator:"-").compactMap {Int($0)}
            let y=b.split(separator:"-").compactMap {Int($0)}
            guard x.count==2, y.count==2 else { return a>b }
            return x[0]*10+x[1] > y[0]*10+y[1]
        }
    }
    var body: some View {
        List {
            if keys.isEmpty {
                Text("Пока нет пробежек. Начни GPS-запись или добавь результат в плане.")
                    .foregroundStyle(.secondary)
            }
            ForEach(keys,id:\.self) { k in
                if let r=cloud.records[k] {
                    VStack(alignment:.leading,spacing:8) {
                        HStack {
                            Text("\(number(r.distance)) км").font(.title3).bold()
                            Spacer()
                            if r.gps?.points.isEmpty == false { Label("GPS",systemImage:"location.fill").font(.caption).foregroundStyle(.green) }
                        }
                        Text("Неделя \(k.replacingOccurrences(of:"-",with:", тренировка ")) · \(duration((r.minutes ?? 0)*60)) · \(pace((r.minutes ?? 0)*60/max(0.01,r.distance)))")
                            .font(.caption).foregroundStyle(.secondary)
                        if !r.notes.isEmpty {Text(r.notes).font(.subheadline)}
                        if r.pain { Label("Отмечена боль",systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                        if r.gps?.points.isEmpty == false {
                            NavigationLink("Карта и экспорт GPX") { RouteDetails(record:r) }
                                .font(.subheadline)
                        }
                    }.padding(.vertical,6)
                    .swipeActions(edge:.trailing) {
                        Button("Удалить",role:.destructive) { confirmDelete=k }
                    }
                }
            }
        }
        .refreshable { await cloud.sync() }
        .alert("Удалить тренировку?",isPresented:Binding(get:{confirmDelete != nil},set:{if !$0 {confirmDelete=nil}})) {
            Button("Удалить",role:.destructive) {
                if let k=confirmDelete {
                    let p=k.split(separator:"-").compactMap {Int($0)}
                    if p.count==2 {cloud.deleteRecord(week:p[0],day:p[1]); Task {await cloud.sync()} }
                }
                confirmDelete=nil
            }
            Button("Отмена",role:.cancel) {confirmDelete=nil}
        } message:{Text("Удалится и GPS-маршрут. Удаление синхронизируется с веб-версией RUN30.")}
    }
}

struct SettingsScreen: View {
    @EnvironmentObject var cloud: CloudStore
    @State private var url=""
    @State private var pubKey=""
    @State private var email=""
    @State private var password=""
    @State private var message=""
    @State private var startDate=Date()
    var body: some View {
        Form {
            Section("Supabase — тот же проект, что на сайте RUN30") {
                TextField("https://xxxx.supabase.co",text:$url)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("Publishable key",text:$pubKey)
                Button("Сохранить проект") {
                    do { try cloud.configure(url:url,key:pubKey);message="Проект сохранён" }
                    catch { message=error.localizedDescription }
                }
                Text("Ключ Publishable публичный. Secret/service_role сюда вводить нельзя.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Аккаунт RUN30") {
                if let e=cloud.loggedInEmail {
                    Text("Вход: \(e)")
                    Button("Выйти") { cloud.signOut() }
                } else {
                    TextField("Email",text:$email).textContentType(.username).textInputAutocapitalization(.never)
                    SecureField("Пароль",text:$password).textContentType(.password)
                    Button("Войти в существующий аккаунт") { Task {await cloud.login(email:email,password:password)} }
                        .disabled(email.isEmpty || password.isEmpty)
                }
                Button("Синхронизировать") { Task { await cloud.sync() } }.disabled(cloud.loggedInEmail == nil)
                Text(cloud.status)
                if let e=cloud.errorText { Text(e).foregroundStyle(.orange).font(.footnote) }
                Text("Ожидают отправки: \(cloud.pendingCount)").font(.caption)
            }
            if !cloud.conflicts.isEmpty {
                Section("Конфликты облачных записей") {
                    ForEach(cloud.conflicts.keys.sorted(),id:\.self) { k in
                        VStack(alignment:.leading,spacing:8) {
                            Text(k).bold()
                            Text("Запись изменена на другом устройстве.").font(.caption)
                            HStack {
                                Button("Оставить мою") {Task {await cloud.resolveConflict(key:k,useLocal:true)}}
                                Button("Взять из облака") {Task {await cloud.resolveConflict(key:k,useLocal:false)}}
                            }.buttonStyle(.bordered)
                        }
                    }
                }
            }
            Section("Дата начала плана") {
                DatePicker("Старт",selection:$startDate,displayedComponents:.date)
                Button("Сохранить дату старта") {cloud.updateStartDate(TrainingPlan.dateISO(startDate));Task {await cloud.sync()}}
            }
            Section {
                Text("Маршрут и тренировки после нажатия «Сохранить» помещаются в локальную очередь, затем передаются в твой Supabase. Не размещай общедоступные GPX: они раскрывают координаты.")
                    .font(.footnote)
                Text("Сборка через Sideloadly с бесплатным Apple ID действует 7 дней; для непрерывной работы регулярно обновляй подпись.")
                    .font(.footnote)
            }
            if !message.isEmpty { Section {Text(message).font(.footnote)} }
        }
        .onAppear {
            url=cloud.projectURL;pubKey=cloud.publishableKey
            let parts=cloud.startDate.split(separator:"-").compactMap{Int($0)}
            if parts.count==3,let d=Calendar.current.date(from:DateComponents(year:parts[0],month:parts[1],day:parts[2])) {startDate=d}
        }
    }
}
