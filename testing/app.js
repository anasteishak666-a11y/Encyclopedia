"use strict";

// Только сценарий показа интерфейса. Реальных ответов, оценивания и авторизации здесь нет.
const screens = ["login", "dashboard", "quiz", "admin"];
const questions = [
  {
    type: "Текстовый вопрос",
    title: "Какую тему вы хотели бы разобрать перед следующей съёмкой?",
    hint: "Учебный пример: здесь нет правильного или неправильного варианта.",
    options: ["Подбор вещей", "Подготовка раскладки", "Планирование публикации"]
  },
  {
    type: "Вопрос с фотографиями",
    title: "Какой снимок вы выбрали бы для обсуждения на занятии?",
    hint: "Фотографии служат примером формата вопроса. Ответ не оценивается.",
    photos: [
      { src: "../Стандарты/Фото на фотофоне/cHV7vxE1qVI.jpg", caption: "Снимок А" },
      { src: "../Стандарты/Фото на фотофоне/G80iHiXHPCk.jpg", caption: "Снимок Б" }
    ],
    options: ["Снимок А", "Снимок Б"]
  }
];
const employees = [
  { name: "Мария Соколова", email: "m.sokolova@example.ru", result: "86%", status: "Пересдача", tone: "warning", history: ["12.10.2026 · Полная аттестация · 86%", "12.07.2026 · Полная аттестация · 92%", "05.07.2026 · Базовый тест · 85%"] },
  { name: "Артём Беляев", email: "a.belyaev@example.ru", result: "94%", status: "Пройдена", tone: "success", history: ["09.10.2026 · Полная аттестация · 94%", "02.10.2026 · Базовый тест · 90%"] },
  { name: "Елена Миронова", email: "e.mironova@example.ru", result: "78%", status: "Пересдача", tone: "warning", history: ["14.10.2026 · Базовый тест · 78%"] },
  { name: "Илья Ветров", email: "i.vetrov@example.ru", result: "—", status: "Приглашён", tone: "muted", history: ["Попыток пока нет"] }
];
const topics = [
  ["Стандарты работы с контентом", "89%"],
  ["Актуальность вещей", "89%"],
  ["Гармоничные образы", "83%"],
  ["Раскладки", "83%"],
  ["Цвет", "75%"],
  ["Анонс", "86%"],
  ["Продавец с вещами", "100%"],
  ["Фото на фотофоне", "100%"],
  ["Фото обуви", "67%"]
];

let questionIndex = 0;
let selectedOption = -1;
let demoDeadline = 0;
let timerInterval = null;
let toastTimeout = null;

function showScreen(name) {
  if (!screens.includes(name)) return;
  for (const screen of screens) {
    document.getElementById(`screen-${screen}`).hidden = screen !== name;
  }
  document.querySelectorAll(".nav-button").forEach(button => {
    const active = button.dataset.go === name;
    button.classList.toggle("is-active", active);
    if (active) button.setAttribute("aria-current", "page");
    else button.removeAttribute("aria-current");
  });
  if (name !== "quiz") stopTimer();
  window.scrollTo({ top: 0, behavior: "smooth" });
}

function showToast(message) {
  const toast = document.getElementById("toast");
  toast.textContent = message;
  toast.hidden = false;
  clearTimeout(toastTimeout);
  toastTimeout = setTimeout(() => { toast.hidden = true; }, 4200);
}

function stopTimer() {
  if (timerInterval) clearInterval(timerInterval);
  timerInterval = null;
}

function updateTimer() {
  const seconds = Math.max(0, Math.ceil((demoDeadline - Date.now()) / 1000));
  const minutes = Math.floor(seconds / 60);
  document.getElementById("question-timer").textContent = `${String(minutes).padStart(2, "0")}:${String(seconds % 60).padStart(2, "0")}`;
  if (seconds === 0) {
    stopTimer();
    showToast("Время демотеста истекло. Показан пример результата.");
    showResult("full");
  }
}

function startQuiz() {
  questionIndex = 0;
  selectedOption = -1;
  demoDeadline = Date.now() + 75 * 60 * 1000;
  showScreen("quiz");
  renderQuestion();
  updateTimer();
  stopTimer();
  timerInterval = setInterval(updateTimer, 1000);
}

function renderQuestion() {
  const question = questions[questionIndex];
  selectedOption = -1;
  document.getElementById("question-number").textContent = `Вопрос ${questionIndex + 1} из ${questions.length}`;
  document.getElementById("question-progress").style.width = `${(questionIndex + 1) / questions.length * 100}%`;
  document.getElementById("question-type").textContent = question.type;
  document.getElementById("question-title").textContent = question.title;
  document.getElementById("question-hint").textContent = question.hint;
  document.getElementById("question-status").textContent = "Выберите вариант ответа.";
  const next = document.getElementById("next-question");
  next.disabled = true;
  next.textContent = questionIndex === questions.length - 1 ? "Завершить демотест →" : "Продолжить →";

  const photoBox = document.getElementById("question-photos");
  photoBox.replaceChildren();
  photoBox.hidden = !question.photos;
  if (question.photos) {
    question.photos.forEach(photo => {
      const figure = document.createElement("figure");
      const image = document.createElement("img");
      const caption = document.createElement("figcaption");
      image.src = photo.src;
      image.alt = photo.caption + " — фотография из энциклопедии";
      caption.textContent = photo.caption;
      figure.append(image, caption);
      photoBox.append(figure);
    });
  }

  const options = document.getElementById("question-options");
  options.replaceChildren();
  question.options.forEach((option, index) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "option";
    button.setAttribute("aria-pressed", "false");
    const mark = document.createElement("span");
    mark.className = "option-mark";
    mark.setAttribute("aria-hidden", "true");
    mark.textContent = String.fromCharCode(1040 + index);
    const label = document.createElement("span");
    label.textContent = option;
    button.append(mark, label);
    button.addEventListener("click", () => {
      selectedOption = index;
      options.querySelectorAll(".option").forEach((item, itemIndex) => {
        const active = itemIndex === index;
        item.classList.toggle("is-selected", active);
        item.setAttribute("aria-pressed", String(active));
      });
      next.disabled = false;
      document.getElementById("question-status").textContent = "Вариант выбран. Нажмите «Продолжить».";
    });
    options.append(button);
  });
}

function showResult(kind) {
  stopTimer();
  showScreen("dashboard");
  const panel = document.getElementById("result-panel");
  const detail = document.getElementById("result-detail");
  detail.replaceChildren();
  panel.hidden = false;
  if (kind === "basic") {
    document.getElementById("result-title").textContent = "Результат базового теста";
    document.getElementById("result-score").textContent = "85%";
    document.getElementById("result-description").textContent = "Вымышленный пример разбора. Эти вопросы не использовались в демотесте.";
    const heading = document.createElement("h3");
    heading.textContent = "Пример вопросов с ошибками";
    const list = document.createElement("ol");
    list.className = "basic-errors";
    ["Вопрос: Какой материал подготовить к учебной встрече? Ответ сотрудника: фотоподборку. Правильный ответ в этом вымышленном примере: план встречи.",
      "Вопрос: Где найти учебный график? Ответ сотрудника: в архиве. Правильный ответ в этом вымышленном примере: в расписании."].forEach(text => {
        const item = document.createElement("li");
        item.textContent = text;
        list.append(item);
      });
    detail.append(heading, list);
  } else {
    document.getElementById("result-title").textContent = "Результат полной аттестации";
    document.getElementById("result-score").textContent = "86%";
    document.getElementById("result-description").textContent = "Вымышленный пример: хорошее знание, пересдача через 7 суток. Выборы в демотесте на балл не влияют.";
    const grid = document.createElement("div");
    grid.className = "result-grid";
    topics.forEach(([topic, score]) => {
      const row = document.createElement("div");
      row.className = "result-topic";
      const label = document.createElement("span");
      label.textContent = `Тема «${topic}»`;
      const value = document.createElement("strong");
      value.textContent = score;
      row.append(label, value);
      grid.append(row);
    });
    const recommendation = document.createElement("p");
    recommendation.className = "recommendation";
    recommendation.append("Рекомендуем повторить темы: ");
    const colorLink = document.createElement("a");
    colorLink.href = "../index.html#chapter-4";
    colorLink.textContent = "Цвет";
    const shoeLink = document.createElement("a");
    shoeLink.href = "../index.html#chapter-6";
    shoeLink.textContent = "Фото обуви";
    recommendation.append(colorLink, " и ", shoeLink, ".");
    detail.append(grid, recommendation);
  }
  panel.scrollIntoView({ behavior: "smooth", block: "start" });
}

function renderEmployees() {
  const body = document.getElementById("employees-body");
  body.replaceChildren();
  employees.forEach((employee, index) => {
    const row = document.createElement("tr");
    [employee.name, employee.email, employee.result].forEach(value => {
      const cell = document.createElement("td");
      cell.textContent = value;
      row.append(cell);
    });
    const statusCell = document.createElement("td");
    const badge = document.createElement("span");
    badge.className = `chip chip--${employee.tone}`;
    badge.textContent = employee.status;
    statusCell.append(badge);
    const actionCell = document.createElement("td");
    const action = document.createElement("button");
    action.type = "button";
    action.className = "text-button";
    action.textContent = "Подробнее →";
    action.addEventListener("click", () => showEmployee(index));
    actionCell.append(action);
    row.append(statusCell, actionCell);
    body.append(row);
  });
}

function showEmployee(index) {
  const employee = employees[index];
  const detail = document.getElementById("employee-detail");
  detail.hidden = false;
  document.getElementById("detail-name").textContent = employee.name;
  document.getElementById("detail-email").textContent = employee.email;
  const stats = document.getElementById("detail-results");
  stats.replaceChildren();
  const strip = document.createElement("div");
  strip.className = "detail-stats";
  [`Последний результат: ${employee.result}`, `Статус: ${employee.status}`].forEach(text => {
    const item = document.createElement("span");
    item.textContent = text;
    strip.append(item);
  });
  stats.append(strip);
  const history = document.getElementById("detail-history");
  history.replaceChildren();
  employee.history.forEach(record => {
    const item = document.createElement("div");
    item.textContent = record;
    history.append(item);
  });
  detail.scrollIntoView({ behavior: "smooth", block: "start" });
}

document.querySelectorAll("[data-go]").forEach(button => {
  button.addEventListener("click", () => {
    if (button.dataset.go === "quiz") startQuiz();
    else showScreen(button.dataset.go);
  });
});
document.getElementById("login-form").addEventListener("submit", event => {
  event.preventDefault();
  showScreen("dashboard");
  showToast("Открыт демонстрационный кабинет. Авторизация не выполнялась.");
});
document.querySelectorAll("[data-start]").forEach(button => button.addEventListener("click", startQuiz));
document.querySelectorAll("[data-result]").forEach(button => button.addEventListener("click", () => showResult(button.dataset.result)));
document.getElementById("next-question").addEventListener("click", () => {
  if (selectedOption < 0) return;
  if (questionIndex < questions.length - 1) {
    questionIndex += 1;
    renderQuestion();
  } else {
    showResult("full");
  }
});
document.getElementById("close-result").addEventListener("click", () => {
  document.getElementById("result-panel").hidden = true;
});
document.getElementById("invite-toggle").addEventListener("click", () => {
  const form = document.getElementById("invite-form");
  form.hidden = !form.hidden;
  if (!form.hidden) form.querySelector("input").focus();
});
document.getElementById("invite-cancel").addEventListener("click", () => {
  document.getElementById("invite-form").hidden = true;
});
document.getElementById("invite-form").addEventListener("submit", event => {
  event.preventDefault();
  const form = event.currentTarget;
  const firstName = form.elements.firstName.value.trim();
  const lastName = form.elements.lastName.value.trim();
  showToast(`Приглашение для ${firstName} ${lastName} показано только в демоверсии. Письмо не отправлено.`);
  form.reset();
  form.hidden = true;
});
document.getElementById("detail-close").addEventListener("click", () => {
  document.getElementById("employee-detail").hidden = true;
});
document.querySelectorAll("[data-demo-action]").forEach(button => {
  button.addEventListener("click", () => showToast(button.dataset.demoAction));
});
renderEmployees();
showScreen("login");
