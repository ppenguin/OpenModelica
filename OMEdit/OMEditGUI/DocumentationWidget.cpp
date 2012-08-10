/*
 * This file is part of OpenModelica.
 *
 * Copyright (c) 1998-CurrentYear, Linkoping University,
 * Department of Computer and Information Science,
 * SE-58183 Linkoping, Sweden.
 *
 * All rights reserved.
 *
 * THIS PROGRAM IS PROVIDED UNDER THE TERMS OF GPL VERSION 3
 * AND THIS OSMC PUBLIC LICENSE (OSMC-PL).
 * ANY USE, REPRODUCTION OR DISTRIBUTION OF THIS PROGRAM CONSTITUTES RECIPIENT'S
 * ACCEPTANCE OF THE OSMC PUBLIC LICENSE.
 *
 * The OpenModelica software and the Open Source Modelica
 * Consortium (OSMC) Public License (OSMC-PL) are obtained
 * from Linkoping University, either from the above address,
 * from the URLs: http://www.ida.liu.se/projects/OpenModelica or
 * http://www.openmodelica.org, and in the OpenModelica distribution.
 * GNU version 3 is obtained from: http://www.gnu.org/copyleft/gpl.html.
 *
 * This program is distributed WITHOUT ANY WARRANTY; without
 * even the implied warranty of  MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE, EXCEPT AS EXPRESSLY SET FORTH
 * IN THE BY RECIPIENT SELECTED SUBSIDIARY LICENSE CONDITIONS
 * OF OSMC-PL.
 *
 * See the full OSMC Public License conditions for more details.
 *
 * Main Authors 2010: Syed Adeel Asghar, Sonia Tariq
 * Contributors 2011: Abhinn Kothari
 */

/*
 * RCS: $Id$
 */

#include "DocumentationWidget.h"

//! @class DocumentationWidget
//! @brief Displays the model documentation.

//! Constructor
//! @param pParent is the pointer to MainWindow.
DocumentationWidget::DocumentationWidget(MainWindow *pParent)
  : QWidget(pParent), mDocumentationFile(QDir::tempPath() + "/OpenModelica/OMEdit/documentation-XXXXXX.html")
{
  setObjectName("DocumentationWidget");
  mpParentMainWindow = pParent;
  mpDocumentationViewer = new DocumentationViewer(this);
  mpDocumentationEditor = new DocumentationEditor(this);
  setIsCustomModel(false);
  mpHeadingLabel = new QPlainTextEdit;
  mpHeadingLabel->setObjectName("DocumentationLabel");
  mpHeadingLabel->setReadOnly(true);
  mpHeadingLabel->setFont(QFont("", Helper::headingFontSize - 5));
  mpPixmapLabel = new QLabel;
  mpPixmapLabel->setObjectName("componentPixmap");
  mpPixmapLabel->setMaximumSize(QSize(86, 86));
  mpPixmapLabel->setFrameStyle(QFrame::Sunken | QFrame::StyledPanel);
  mpPixmapLabel->setAlignment(Qt::AlignCenter);
  // create buttons
  mpEditButton = new QPushButton(Helper::edit);
  mpEditButton->setAutoDefault(true);
  mpEditButton->setMaximumSize(QSize(120,20));
  connect(mpEditButton, SIGNAL(clicked()), SLOT(editDocumentation()));
  mpSaveButton = new QPushButton(Helper::save);
  mpSaveButton->setAutoDefault(false);
  mpSaveButton->setMaximumSize(QSize(100,20));
  connect(mpSaveButton, SIGNAL(clicked()), SLOT(saveChanges()));
  QHBoxLayout *horizontalLayout = new QHBoxLayout;
  horizontalLayout->setAlignment(Qt::AlignTop | Qt::AlignLeft);
  horizontalLayout->addWidget(mpPixmapLabel);
  horizontalLayout->addWidget(mpHeadingLabel);
  horizontalLayout->addWidget(mpSaveButton);
  horizontalLayout->addWidget(mpEditButton);
  // set layout
  QVBoxLayout *verticalLayout = new QVBoxLayout;
  verticalLayout->setAlignment(Qt::AlignTop | Qt::AlignLeft);
  verticalLayout->addLayout(horizontalLayout);
  verticalLayout->addWidget(mpDocumentationViewer);
  verticalLayout->addWidget(mpDocumentationEditor);
  setLayout(verticalLayout);
}

//! Destructor
DocumentationWidget::~DocumentationWidget()
{
  delete mpDocumentationViewer;
  delete mpDocumentationEditor;
}

//! Shows the documentation of a model
//! @param className the model name
void DocumentationWidget::show(QString className)
{
  mClassName = className;
  mpHeadingLabel->setPlainText(className);

  LibraryComponent *libraryComponent = mpParentMainWindow->mpLibrary->getLibraryComponentObject(className);
  if(libraryComponent)
  {
    mpPixmapLabel->setVisible(true);
    mpPixmapLabel->setPixmap(libraryComponent->getComponentPixmap(QSize(75, 75)));
  }
  else
  {
    mpPixmapLabel->setVisible(false);
  }
  // show edit and save buttons if show is called for a custom model
  if (isCustomModel())
  {
    mpEditButton->setVisible(true);
    mpEditButton->setDisabled(false);
    mpSaveButton->setVisible(true);
    mpSaveButton->setDisabled(true);
  }
  else
  {
    mpEditButton->setVisible(false);
    mpSaveButton->setVisible(false);
  }
  QString documentation = mpParentMainWindow->mpOMCProxy->getDocumentationAnnotation(className);
  /* Create a local file with the html we want to view as otherwise
   * JavaScript does not run properly.
   */
  mDocumentationFile.open();
  QTextStream out(&mDocumentationFile);
  out << documentation;
  mDocumentationFile.close();
  
  mpDocumentationViewer->setUrl(mDocumentationFile.fileName());
  mpDocumentationViewer->setVisible(true);
  mpDocumentationEditor->setVisible(false);
}

//! Shows the documenation editing view.
//! @param className the model name
void DocumentationWidget::showDocumentationEditView(QString className)
{
  mpDocumentationViewer->hide();
  // get the already existing documentation text of the model
  mpDocumentationEditor->toPlainText();
  if (!mpParentMainWindow->mpOMCProxy->getDocumentationAnnotation(className).isEmpty())
    mpDocumentationEditor->setPlainText(mpParentMainWindow->mpOMCProxy->getDocumentationAnnotation(className));
  else
    mpDocumentationEditor->setPlainText("<html>\n\n</html>");
  mpDocumentationEditor->setFocus();
  mpDocumentationEditor->show();
}

//! Sets the model as custom model.
//! @param isCustomModel
void DocumentationWidget::setIsCustomModel(bool isCustomModel)
{
  mIsCustomModel = isCustomModel;
}

//! Returns true if the model is a custom model.
//! @return bool true if model is a custom model
bool DocumentationWidget::isCustomModel()
{
  return mIsCustomModel;
}

//! Reimplementation of paintevent. Draws a rectangle around QWidget
void DocumentationWidget::paintEvent(QPaintEvent *event)
{
  QPainter painter(this);
  painter.setPen(Qt::gray);
  QRect rectangle = rect();
  rectangle.setWidth(rect().width() - 1);
  rectangle.setHeight(rect().height() - 1);
  painter.drawRect(rectangle);
  QWidget::paintEvent(event);
}

void DocumentationWidget::editDocumentation()
{
  showDocumentationEditView(mClassName);
  mpEditButton->setDisabled(true);
  mpSaveButton->setDisabled(false);
}

//! Save the changes made to the documentation of the model.
void DocumentationWidget::saveChanges()
{
  QString doc = mpDocumentationEditor->toPlainText();
  if(doc.startsWith("<html>", Qt::CaseInsensitive) && doc.endsWith("</html>", Qt::CaseInsensitive))
  {
    mpParentMainWindow->mpOMCProxy->addClassAnnotation(mClassName,"annotate=Documentation(info = \""+StringHandler::escape(doc)+"\")");
    show(mClassName);
  }
  else
  {
    QString message = QString(GUIMessages::getMessage(GUIMessages::INCORRECT_HTML_TAGS));
    mpParentMainWindow->mpMessageWidget->addGUIProblem(new ProblemItem("", false, 0, 0, 0, 0, message, Helper::scriptingKind,
                                                                       Helper::errorLevel, 0, mpParentMainWindow->mpMessageWidget->mpProblem));
  }
}

//! @class DocumentationEditor
//! @brief An editor for editing the documentation of the model.

//! Constructor
//! @param pParent is the pointer to DocumentationWidget.
DocumentationEditor::DocumentationEditor(DocumentationWidget *pParent)
  : QTextEdit(pParent)
{
  mpParentDocumentationWidget = pParent;
  setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOn);
  setVerticalScrollBarPolicy(Qt::ScrollBarAlwaysOn);
  setTabStopWidth(Helper::tabWidth);
  setObjectName("DocumentationEditor");
  setAutoFormatting(QTextEdit::AutoNone);
  setAcceptRichText(false);
  setFontFamily(qApp->font().family());             // get system font
  setFontPointSize(10.0);
}

//! @class DocumentationViewer
//! @brief A webview for displaying the html documentation.

//! Constructor
//! @param pParent is the pointer to DocumentationWidget.
DocumentationViewer::DocumentationViewer(DocumentationWidget *pParent)
  : QWebView(pParent)
{
  mpParentDocumentationWidget = pParent;
  // set the base url for documentation.
  mpParentDocumentationWidget->mpParentMainWindow->mpOMCProxy->sendCommand("getNamedAnnotation(Modelica,version)");
  QStringList lst = StringHandler::unparseStrings(mpParentDocumentationWidget->mpParentMainWindow->mpOMCProxy->getResult());
  QString versionStr = lst.empty() ? "" : lst.at(0);
  // We need to replace the back slashes(\) with forward slash(/), since QWebView baseurl doesn't handle it.
  QString baseUrl = QString(Helper::OpenModelicaLibrary).replace("\\", "/").append("/Modelica ").append(versionStr).append("/Images/");
  setBaseUrl(baseUrl);
  // set page font settings
  settings()->setFontFamily(QWebSettings::StandardFont, "Verdana");
  settings()->setFontSize(QWebSettings::DefaultFontSize, 10);
  settings()->setAttribute(QWebSettings::LocalStorageEnabled, 1);
  // set page links settings
  page()->setLinkDelegationPolicy(QWebPage::DelegateAllLinks);

  connect(this, SIGNAL(linkClicked(QUrl)), SLOT(processLinkClick(QUrl)));
  connect(page(), SIGNAL(linkHovered(QString,QString,QString)), SLOT(processLinkHover(QString,QString,QString)));
}

//! Sets a base url for the webview.
//! @param url the base url
void DocumentationViewer::setBaseUrl(QString url)
{
  mBaseUrl.setUrl(url);
}

//! Returns the base url.
//! @return QUrl the base url.
QUrl DocumentationViewer::getBaseUrl()
{
  return mBaseUrl;
}

//! Slot activated when linkClicked signal of webview is raised.
//! Handles the link processing. Sends all the http starting links to the QDesktopServices and process all Modelica starting links.
void DocumentationViewer::processLinkClick(QUrl url)
{
  //! @todo
  /* Send all http requests to desktop services for now. If we need to display web pages then we will change it,
       but for now else portion is never reached. */

  // if url contains http or mailto: send it to desktop services
  if ((url.toString().startsWith("http")) or (url.toString().startsWith("mailto:")))
  {
    QDesktopServices::openUrl(url);
  }

  // if the user has clicked on some Modelica Links like Modelica://
  else if (url.toString().startsWith("Modelica", Qt::CaseInsensitive))
  {
    // remove Modelica:// from link
    QString className;
    className = url.toString().mid(10, url.toString().length() - 1);
    // send the new className to DocumentationWidget
    mpParentDocumentationWidget->show(className);
  }
  // if it is normal http request then check if its not redirected to https
  else
  {
    QNetworkAccessManager* accessManager = page()->networkAccessManager();
    QNetworkRequest request(url);
    QNetworkReply* reply = accessManager->get(request);
    connect(reply, SIGNAL(finished()), SLOT(requestFinished()));
  }
}

//! Slot activated when QNetworkReply finished signal is raised.
//! Handles the link redirected to https.
void DocumentationViewer::requestFinished()
{
  QNetworkReply *reply = qobject_cast<QNetworkReply*>(const_cast<QObject*>(sender()));
  QUrl possibleRedirectedUrl = reply->attribute(QNetworkRequest::RedirectionTargetAttribute).toUrl();

  //if the url contains https
  if (possibleRedirectedUrl.toString().contains("https"))
    QDesktopServices::openUrl(possibleRedirectedUrl);
  else
    load(reply->url());

  reply->deleteLater();
}

//! Slot activated when linkHovered signal of web view is raised.
//! Writes the url to the status bar.
void DocumentationViewer::processLinkHover(QString link, QString title, QString textContent)
{
  Q_UNUSED(title);
  Q_UNUSED(textContent);

  if (link.isEmpty())
    mpParentDocumentationWidget->mpParentMainWindow->mpStatusBar->clearMessage();
  else
    mpParentDocumentationWidget->mpParentMainWindow->mpStatusBar->showMessage(link);
}

//! Reimplementation of mousePressEvent.
//! Disables the webview rightclick.
void DocumentationViewer::mousePressEvent(QMouseEvent *event)
{
  // dont allow right click on Documentation Viewer
  if (event->button() == Qt::LeftButton)
  {
    QWebView::mousePressEvent(event);
  }
  else if (event->button() == Qt::RightButton)
  {
    event->ignore();
  }
}

QWebView *DocumentationViewer::createWindow(QWebPage::WebWindowType type)
{
    Q_UNUSED(type);
 
    QWebView *webView = new QWebView;
    QWebPage *newWeb = new QWebPage(webView);
    webView->setAttribute(Qt::WA_DeleteOnClose, true);
    webView->setPage(newWeb);
    webView->show();
 
    return webView;
}
