# Backend - Flask 伺服器

基於Flask的後端API服務，處理UWB定位數據和音響控制。

## 功能特點

- UWB串口數據讀取和處理
- 伺服馬達角度控制
- 智慧音量調節
- 三種工作模式：自動、自定義、手動
- RESTful API介面

## API端點

### 模式控制
- `POST /mode` - 設定工作模式
- `GET /current-data` - 獲取當前UWB數據

### 音量控制
- `POST /volume` - 設定手動音量

### 伺服馬達控制
- `POST /servo/tracking` - 設定自動/手動追蹤模式
- `POST /servo/angle` - 設定伺服馬達角度

### 位置管理
- `GET /positions` - 獲取所有自定義位置
- `POST /position` - 新增自定義位置
- `DELETE /position/<name>` - 刪除指定位置

### 系統資訊
- `GET /pi-ip` - 獲取系統IP地址

## 安裝與運行

1. 安裝依賴
```bash
pip install -r requirements.txt
```

2. 運行服務
```bash
python app.py
```

服務將運行在 `http://0.0.0.0:5000`

## 硬體需求

- Raspberry Pi 4
- UWB模組（串口連接）
- 伺服馬達（GPIO 17）
